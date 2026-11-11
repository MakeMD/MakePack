//! MP-B: `MakePack --selftest` (Program.SelfTest): end-to-end checks through the real 7z.dll in a fresh
//! %TEMP%\MakePack-selftest-<random> folder (removed afterwards). Prints "OK <what>" / "FAIL <what>: <why>" lines to
//! stdout, then "ALL OK" or "N FAILED"; exit code 0 / 1 (as C#). The Recycle Bin is used only for files under that
//! folder, and whatever the run sent there is put back (fromRecycleBin). The SFX run happens on a hidden desktop.
//! `runIn` is the same run for `zig build test-engine` (src/test_engine.zig).
//! "gui" drives the main window's model (src/ui/mw_model.zig) without a window, as C# drove a MainForm never shown.
//! Beyond C#: "registry" (MP-C assoc verbs under HKCU\Software\MakePackTest-<random>) and "single" (mutex + pipe
//! on a private name).
const std = @import("std");
const kit = @import("kit");
const engine = @import("core/engine.zig");
const types = @import("core/types.zig");
const settings = @import("settings.zig");
const S = @import("strings.zig");
const cli = @import("platform/cli.zig");
const assoc = @import("platform/assoc.zig");
const single = @import("platform/single.zig");
const mw = @import("ui/mw_model.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const w = kit.w;
const fspath = Io.Dir.path;
const ArchiveKind = types.ArchiveKind;
const CompressOptions = types.CompressOptions;
const OverwriteMode = types.OverwriteMode;
const fileExists = engine.fileExists;
const dirExists = engine.dirExists;

/// The command: console, 7z.dll next to the exe, a fresh temp folder, every check. Exit code 0 / 1.
pub fn run(gpa: Allocator, io: Io) anyerror!u8 {
    cli.useConsole();
    var obuf: [4096]u8 = undefined;
    var fo = Io.File.stdout().writer(io, &obuf);
    const out = &fo.interface;
    defer out.flush() catch {};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var wbuf: [2048]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &wbuf, wbuf.len);
    const exe = try std.unicode.wtf16LeToWtf8Alloc(ar, wbuf[0..n]);
    const dir = fspath.dirname(exe) orelse ".";
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    var tbuf: [w.MAX_PATH + 1]u16 = undefined;
    const tn = w.GetTempPathW(tbuf.len, &tbuf);
    const tmp = std.mem.trimEnd(u8, try std.unicode.wtf16LeToWtf8Alloc(ar, tbuf[0..tn]), "\\");
    const root = try ar.print("{s}\\MakePack-selftest-{x}", .{ tmp, &rnd });
    const fails = runIn(gpa, io, dir, root, out);
    if (fails == 0) out.print("ALL OK\r\n", .{}) catch {} else out.print("{d} FAILED\r\n", .{fails}) catch {};
    return if (fails == 0) 0 else 1;
}

/// Every check against 7z.dll in `engine_dir`, in `root` (created here, removed afterwards; the engine's temp dirs
/// too). Returns the number of failed checks. Shared by `run` and src/test_engine.zig.
pub fn runIn(gpa: Allocator, io: Io, engine_dir: []const u8, root: []const u8, out: *Io.Writer) u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var t: T = .{ .gpa = gpa, .io = io, .ar = arena.allocator(), .root = root, .engine_dir = engine_dir, .out = out };
    defer engine.nuke(io, root);
    defer engine.deinit(io); // the engine's temp dirs (ProcessExit in C#)
    setup(&t) catch |e| {
        t.say("FAIL setup: {t}", .{e});
        return 1;
    };
    engine.init(gpa, io, engine_dir) catch |e| { // repeatable: the test runner may have done it already
        t.say("FAIL setup: 7z.dll in {s}: {t}", .{ engine_dir, e });
        return 1;
    };
    inline for (.{ ArchiveKind.SevenZip, .Zip, .Tar, .TarGz, .TarBz2, .TarXz, .Wim }) |k| t.check(@tagName(k), struct {
        fn f(x: *T) !void {
            _ = try roundTrip(x, k, x.src, .{}, "");
        }
    }.f);
    t.check("7z+password", password7z);
    t.check("zip+aes", zipAes);
    t.check("empty_dirs", emptyDirs);
    t.check("append", appendCheck);
    t.check("append_replace", appendReplace);
    t.check("rename_file", renameFile);
    t.check("rename_folder", renameFolder);
    t.check("edit_guard", editGuard);
    t.check("delete", deleteCheck);
    t.check("check", checkCheck);
    t.check("GZip", gzipCheck);
    t.check("conflicts", conflicts);
    t.check("probe", probeCheck);
    t.check("methods", methods);
    t.check("advanced_7z", advanced7z);
    t.check("advanced_guard", advancedGuard);
    t.check("volumes", volumes);
    t.check("after_actions", afterActions);
    t.check("separate", separate);
    t.check("sfx", sfx);
    t.check("zipcrypto", zipCrypto);
    t.check("settings", settingsCheck);
    t.check("motw", motw);
    t.check("extract_options", extractOptions);
    t.check("shellnew", shellNew);
    t.check("info", info);
    t.check("report", reportCheck);
    t.check("convert", convertCheck);
    t.check("profiles", profiles);
    // MP-C hook: the CLI end to end through cli.run (MP-C owns its own tests: test-platform, tools/bugtest.ps1).
    t.check("cli", cliCheck);
    t.check("packed", packedCheck);
    t.check("registry", registryCheck);
    t.check("single", singleCheck);
    t.check("gui", guiCheck);
    return t.fails;
}

// ---- the harness ------------------------------------------------------------------------------------------

const T = struct {
    gpa: Allocator,
    io: Io,
    /// Everything the run allocates (paths, lists); freed at the end.
    ar: Allocator,
    root: []const u8,
    engine_dir: []const u8,
    out: *Io.Writer,
    src: []const u8 = "",
    text: []const u8 = "",
    extra: []const u8 = "",
    why: [1024]u8 = undefined,
    why_len: usize = 0,
    diag: engine.Diag = .{},
    fails: u32 = 0,

    fn say(t: *T, comptime fmt: []const u8, args: anytype) void {
        t.out.print(fmt ++ "\r\n", args) catch {};
        t.out.flush() catch {};
    }

    fn check(t: *T, name: []const u8, f: *const fn (*T) anyerror!void) void {
        t.why_len = 0;
        t.diag = .{};
        f(t) catch |e| {
            const msg = if (t.why_len > 0) t.why[0..t.why_len] else engine.friendly(e, &t.diag);
            t.say("FAIL {s}: {s} ({t})", .{ name, msg, e });
            t.fails += 1;
        };
    }

    fn must(t: *T, ok: bool, comptime fmt: []const u8, args: anytype) !void {
        if (ok) return;
        var wr: Io.Writer = .fixed(&t.why);
        wr.print(fmt, args) catch {};
        t.why_len = wr.buffered().len;
        return error.CheckFailed;
    }

    /// root\rel
    fn p(t: *T, rel: []const u8) ![]const u8 {
        return join(t.ar, &.{ t.root, rel });
    }
};

fn join(ar: Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.join(ar, "\\", parts);
}

fn writeFile(t: *T, path: []const u8, data: []const u8) !void {
    if (fspath.dirname(path)) |d| try Io.Dir.cwd().createDirPath(t.io, d);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = data });
}

fn readFile(t: *T, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(t.io, path, t.ar, .limited(256 << 20));
}

fn size(t: *T, path: []const u8) u64 {
    return (Io.Dir.cwd().statFile(t.io, path, .{}) catch return 0).size;
}

fn noise(t: *T, path: []const u8, n: usize, rng: std.Random) !void {
    const b = try t.ar.alloc(u8, n);
    rng.bytes(b);
    try writeFile(t, path, b);
}

/// Program.Same: every folder and file of `expected` is in `actual`, byte for byte.
fn same(t: *T, expected: []const u8, actual: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(t.io, expected, .{ .iterate = true });
    defer dir.close(t.io);
    var walker = try dir.walk(t.gpa);
    defer walker.deinit();
    while (try walker.next(t.io)) |e| {
        const other = try join(t.ar, &.{ actual, e.path });
        if (e.kind == .directory) {
            try t.must(dirExists(other), "missing folder {s}", .{e.path});
        } else {
            try t.must(fileExists(other), "missing {s}", .{e.path});
            const a = try readFile(t, try join(t.ar, &.{ expected, e.path }));
            try t.must(std.mem.eql(u8, a, try readFile(t, other)), "differs {s}", .{e.path});
        }
    }
}

/// Files under `dir`, recursively, relative with '/', sorted (Directory.EnumerateFiles + Order()).
fn filesUnder(t: *T, dir: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(t.io, dir, .{ .iterate = true }) catch return list.items;
    defer d.close(t.io);
    var walker = try d.walk(t.gpa);
    defer walker.deinit();
    while (try walker.next(t.io)) |e| if (e.kind != .directory) {
        const rel = try t.ar.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        try list.append(t.ar, rel);
    };
    std.mem.sort([]const u8, list.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f);
    return list.items;
}

/// Names in `dir` that start with `prefix` (Directory.GetFiles(dir, prefix + "*")).
fn namesLike(t: *T, dir: []const u8, prefix: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var d = try Io.Dir.cwd().openDir(t.io, dir, .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    while (try it.next(t.io)) |e| if (std.ascii.startsWithIgnoreCase(e.name, prefix)) try list.append(t.ar, try join(t.ar, &.{ dir, e.name }));
    return list.items;
}

fn pack(t: *T, inputs: []const []const u8, archive: []const u8, k: ArchiveKind, password: ?[]const u8, he: bool) !void {
    try engine.compress(t.gpa, t.io, inputs, archive, k, .{ .password = password, .encrypt_headers = he }, .none, &t.diag);
}

fn compress(t: *T, inputs: []const []const u8, archive: []const u8, k: ArchiveKind, o: CompressOptions) !void {
    try engine.compress(t.gpa, t.io, inputs, archive, k, o, .none, &t.diag);
}

fn open(t: *T, archive: []const u8, password: ?[]const u8) !*engine.Archive {
    return engine.open(t.gpa, t.io, archive, password, .none, &t.diag);
}

fn unpack(t: *T, a: *engine.Archive, dest: []const u8, mode: OverwriteMode) !void {
    try engine.extract(t.gpa, t.io, a, dest, null, mode, .none, .always_overwrite, .Never, .{}, &t.diag);
}

fn count(t: *T, archive: []const u8, password: ?[]const u8) !usize {
    const a = try open(t, archive, password);
    defer a.close();
    return a.items().len;
}

fn opens(t: *T, archive: []const u8) bool {
    const a = engine.open(t.gpa, t.io, archive, null, .none, null) catch return false;
    a.close();
    return true;
}

fn answer(comptime mode: OverwriteMode) engine.Conflict {
    return .{ .ask = struct {
        fn f(_: ?*anyopaque, _: []const u8) ?OverwriteMode {
            return mode;
        }
    }.f };
}

fn appendTo(t: *T, archive: []const u8, password: ?[]const u8, inputs: []const []const u8, prefix: []const u8, comptime mode: OverwriteMode) !void {
    const a = try open(t, archive, password);
    try engine.append(t.gpa, t.io, a, inputs, prefix, .{}, .none, answer(mode), &t.diag);
}

/// CancelOnReport (any = true) / CancelPast(percent).
const Canceler = struct {
    flag: std.atomic.Value(bool) = .init(false),
    any: bool = false,
    past: u8 = 0,

    fn progress(c: *Canceler) engine.Progress {
        return .{ .ctx = c, .report = report, .cancel = &c.flag };
    }

    fn report(ctx: ?*anyopaque, percent: u8, _: []const u8) void {
        const c: *Canceler = @ptrCast(@alignCast(ctx));
        if (c.any or percent > c.past) c.flag.store(true, .release);
    }
};

/// Copies root\name to root\copy (the edits work on copies, so the fixtures stay as packed).
fn fresh(t: *T, name: []const u8, copy: []const u8) ![]const u8 {
    const to = try t.p(copy);
    try Io.Dir.cwd().copyFile(try t.p(name), Io.Dir.cwd(), to, t.io, .{});
    return to;
}

/// Program.RoundTrip: packs, lists, unpacks and compares. Returns the per-file Method strings.
fn roundTrip(t: *T, k: ArchiveKind, src: []const u8, o: CompressOptions, tag: []const u8) ![]const []const u8 {
    const name = try t.ar.print("{s}{s}", .{ @tagName(k), tag });
    const archive = try t.p(try std.mem.concat(t.ar, u8, &.{ name, types.kind(k).ext }));
    try compress(t, &.{src}, archive, k, o);
    const a = try open(t, archive, null);
    defer a.close();
    var used: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;
    for (a.items()) |it| if (!it.is_dir) {
        files += 1;
        if (it.size > 0) try used.append(t.ar, try t.ar.dupe(u8, it.method));
    };
    try t.must(files >= 4, "listed {d} file entries, expected 4+", .{files});
    const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "out-", name }));
    try unpack(t, a, dest, .Overwrite);
    try same(t, src, try join(t.ar, &.{ dest, fspath.basename(src) }));
    t.say("OK {s} ({d} bytes)", .{ name, size(t, archive) });
    return used.items;
}

/// Program.FromRecycleBin: puts back what this run sent to the Recycle Bin (items whose original location is under
/// root), so the selftest proves the bin got them and leaves the user's bin as it found it. Returns the count.
/// The bin is read directly: <drive>\$Recycle.Bin\<SID>\$I* hold the original path, $R* the item itself.
fn fromRecycleBin(t: *T) !usize {
    const bin = try std.mem.concat(t.ar, u8, &.{ t.root[0..3], "$Recycle.Bin" });
    var top = Io.Dir.cwd().openDir(t.io, bin, .{ .iterate = true }) catch return 0;
    defer top.close(t.io);
    var restored: usize = 0;
    var sids = top.iterate();
    while (try sids.next(t.io)) |sid| {
        const dir = try join(t.ar, &.{ bin, sid.name });
        var d = Io.Dir.cwd().openDir(t.io, dir, .{ .iterate = true }) catch continue; // other users' bins
        defer d.close(t.io);
        var it = d.iterate();
        var found: std.ArrayList([]const u8) = .empty;
        while (try it.next(t.io)) |e| if (std.mem.startsWith(u8, e.name, "$I")) try found.append(t.ar, try t.ar.dupe(u8, e.name));
        for (found.items) |name| {
            const i_path = try join(t.ar, &.{ dir, name });
            const data = readFile(t, i_path) catch continue;
            if (data.len < 28) continue;
            const version = std.mem.readInt(u64, data[0..8], .little);
            const at: usize = if (version >= 2) 28 else 24;
            const units = (data.len - at) / 2;
            const wide = try t.ar.alloc(u16, units);
            for (wide, 0..) |*c, k| c.* = std.mem.readInt(u16, data[at + 2 * k ..][0..2], .little);
            const end = std.mem.findScalar(u16, wide, 0) orelse wide.len;
            const from = try std.unicode.wtf16LeToWtf8Alloc(t.ar, wide[0..end]);
            if (from.len < t.root.len or !types.eqlIgnoreCase(from[0..t.root.len], t.root)) continue;
            const r_path = try join(t.ar, &.{ dir, try std.mem.concat(t.ar, u8, &.{ "$R", name[2..] }) });
            Io.Dir.renameAbsolute(r_path, from, t.io) catch continue;
            Io.Dir.cwd().deleteFile(t.io, i_path) catch {};
            restored += 1;
        }
    }
    return restored;
}

/// A stored zip by hand (System.IO.Compression's ZipFile in C#): names Windows itself would never allow.
fn writeZip(t: *T, path: []const u8, entries: []const [2][]const u8) !void {
    var aw: Io.Writer.Allocating = .init(t.ar);
    var cd: Io.Writer.Allocating = .init(t.ar);
    const z = &aw.writer;
    for (entries) |e| {
        const offset: u32 = @intCast(aw.written().len);
        const crc = std.hash.Crc32.hash(e[1]);
        const len: u32 = @intCast(e[1].len);
        const nlen: u16 = @intCast(e[0].len);
        // local header: sig, version 20, flags (bit 11 = UTF-8 name), stored, time 0, date 1980-01-01
        try z.writeInt(u32, 0x04034b50, .little);
        inline for (.{ @as(u16, 20), @as(u16, 0x800), @as(u16, 0), @as(u16, 0), @as(u16, 0x21) }) |v| try z.writeInt(u16, v, .little);
        inline for (.{ crc, len, len }) |v| try z.writeInt(u32, v, .little);
        try z.writeInt(u16, nlen, .little);
        try z.writeInt(u16, 0, .little);
        try z.writeAll(e[0]);
        try z.writeAll(e[1]);
        const c = &cd.writer;
        try c.writeInt(u32, 0x02014b50, .little);
        inline for (.{ @as(u16, 20), @as(u16, 20), @as(u16, 0x800), @as(u16, 0), @as(u16, 0), @as(u16, 0x21) }) |v| try c.writeInt(u16, v, .little);
        inline for (.{ crc, len, len }) |v| try c.writeInt(u32, v, .little);
        inline for (.{ nlen, @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0) }) |v| try c.writeInt(u16, v, .little);
        try c.writeInt(u32, 0, .little);
        try c.writeInt(u32, offset, .little);
        try c.writeAll(e[0]);
    }
    const cd_offset: u32 = @intCast(aw.written().len);
    try z.writeAll(cd.written());
    try z.writeInt(u32, 0x06054b50, .little);
    const n: u16 = @intCast(entries.len);
    inline for (.{ @as(u16, 0), @as(u16, 0), n, n }) |v| try z.writeInt(u16, v, .little);
    try z.writeInt(u32, @intCast(cd.written().len), .little);
    try z.writeInt(u32, cd_offset, .little);
    try z.writeInt(u16, 0, .little);
    try writeFile(t, path, aw.written());
}

/// 2001-01-15 00:00 UTC (winter: zip's local DOS time cannot shift by DST): the empty folder's time.
const old_unix = 979516800;
const old_ticks: u64 = (old_unix + 11644473600) * 10_000_000;

/// File.SetLastWriteTime / Directory.SetLastWriteTime (FILETIME ticks, UTC).
fn setMtime(path: []const u8, ticks: u64) !void {
    const wp = try kit.win.toW(std.heap.smp_allocator, path);
    defer std.heap.smp_allocator.free(wp);
    const share: w.DWORD = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
    const h = w.CreateFileW(wp.ptr, w.FILE_WRITE_ATTRIBUTES, share, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null); // folders too
    if (h == w.INVALID_HANDLE_VALUE) return error.FileNotFound;
    defer _ = w.CloseHandle(h);
    const ft: w.FILETIME = .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
    if (w.SetFileTime(h, null, null, &ft) == 0) return error.Unexpected;
}

/// The call failed with exactly `e` (error unions do not compare with ==).
fn is(r: anytype, e: anyerror) bool {
    _ = r catch |x| return x == e;
    return false;
}

fn now() u64 {
    var ft: w.FILETIME = undefined;
    w.GetSystemTimeAsFileTime(&ft);
    return @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
}

/// Runs `exe args` on a desktop of its own (nothing shows on the user's screen); its exit code, null on timeout.
fn runHidden(t: *T, exe: []const u8, args: []const u8, timeout_ms: u32) !?u32 {
    var rnd: [4]u8 = undefined;
    t.io.random(&rnd);
    const desk_name = try kit.win.toW(t.ar, try t.ar.print("MakePackSelftest{x}", .{&rnd}));
    const desk = w.CreateDesktopW(desk_name.ptr, null, null, 0, @intCast(w.GENERIC_ALL), null) orelse return error.Unexpected;
    defer _ = w.CloseDesktop(desk);
    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    si.lpDesktop = desk_name.ptr;
    var pi: w.PROCESS_INFORMATION = undefined;
    const cmd = try kit.win.toW(t.ar, try t.ar.print("\"{s}\" {s}", .{ exe, args }));
    if (w.CreateProcessW(null, cmd.ptr, null, null, 0, 0, null, null, &si, &pi) == 0) return error.Unexpected;
    defer {
        _ = w.CloseHandle(pi.hThread);
        _ = w.CloseHandle(pi.hProcess);
    }
    if (w.WaitForSingleObject(pi.hProcess, timeout_ms) != w.WAIT_OBJECT_0) {
        _ = w.TerminateProcess(pi.hProcess, 1); // ours, by handle
        return null;
    }
    var code: w.DWORD = 0;
    _ = w.GetExitCodeProcess(pi.hProcess, &code);
    return code;
}

/// The running exe (MakePack.exe, or the test binary).
fn ownExe(t: *T) ![]const u8 {
    var wbuf: [2048]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &wbuf, wbuf.len);
    return std.unicode.wtf16LeToWtf8Alloc(t.ar, wbuf[0..n]);
}

/// Damages only a 7z's packed streams (the headers stay readable): it opens, and its test fails.
fn damagePacked(path: []const u8) void {
    const b = Io.Dir.cwd().readFileAlloc(hook_io, path, std.heap.smp_allocator, .limited(64 << 20)) catch return;
    defer std.heap.smp_allocator.free(b);
    // The front only: 7z keeps its compressed file list as the last packed stream, right before the next header.
    const end: usize = 32 + @as(usize, @intCast(@min(std.mem.readInt(u64, b[12..20], .little) / 4, 16)));
    for (b[32..end]) |*c| c.* ^= 0x5A;
    Io.Dir.cwd().writeFile(hook_io, .{ .sub_path = path, .data = b }) catch {};
}

/// Damages the packed stream (not the signature): a bad disk between write and test.
var hook_io: Io = undefined;
fn damage(path: []const u8) void {
    const b = Io.Dir.cwd().readFileAlloc(hook_io, path, std.heap.smp_allocator, .limited(64 << 20)) catch return;
    defer std.heap.smp_allocator.free(b);
    var i: usize = 40;
    while (i + 40 < b.len) : (i += 7) b[i] ^= 0x5A;
    Io.Dir.cwd().writeFile(hook_io, .{ .sub_path = path, .data = b }) catch {};
}

// ---- fixtures ------------------------------------------------------------------------------------------

fn setup(t: *T) !void {
    t.src = try t.p("src");
    try Io.Dir.cwd().createDirPath(t.io, try join(t.ar, &.{ t.src, "sub", "deeper" }));
    var prng: std.Random.DefaultPrng = .init(20260913);
    try noise(t, try join(t.ar, &.{ t.src, "a.txt" }), 10 * 1024, prng.random());
    try noise(t, try join(t.ar, &.{ t.src, "sub", "b.bin" }), 1024 * 1024, prng.random());
    try writeFile(t, try join(t.ar, &.{ t.src, "sub", "deeper", "тест ïé.txt" }), "Привіт, світ! ïé\r\n");
    try writeFile(t, try join(t.ar, &.{ t.src, "empty.txt" }), "");
    try Io.Dir.cwd().createDirPath(t.io, try join(t.ar, &.{ t.src, "void", "deeper" })); // empty folders: same() checks they come back
    try setMtime(try join(t.ar, &.{ t.src, "void", "deeper" }), old_ticks); // ... with their own time (emptyDirs)
    t.extra = try t.p("extra.txt");
    try writeFile(t, t.extra, "appended later");
    // Compressible text: on noise zip just stores every file, and the method under test never shows.
    t.text = try t.p("text");
    for ([_][]const u8{ "a.txt", "b.txt", "sub/c.txt", "sub/d.txt" }, 0..) |n, i| {
        var aw: Io.Writer.Allocating = .init(t.ar);
        for (0..20000) |k| try aw.writer.print("line {d} of {s}\n", .{ k * (i + 1), n });
        const rel = try t.ar.dupe(u8, n);
        std.mem.replaceScalar(u8, rel, '/', '\\');
        try writeFile(t, try join(t.ar, &.{ t.text, rel }), aw.written());
    }
}

// ---- the checks (Program.SelfTest, in its order) ------------------------------------------------------------

fn password7z(t: *T) !void {
    const archive = try t.p("secret.7z");
    try pack(t, &.{t.src}, archive, .SevenZip, "hunter2", true);
    try t.must(!opens(t, archive), "opened with encrypted headers and no password", .{});
    const a = try open(t, archive, "hunter2");
    defer a.close();
    try unpack(t, a, try t.p("out-secret"), .Overwrite);
    try same(t, t.src, try t.p("out-secret\\src"));
    t.say("OK 7z+password ({d} bytes)", .{size(t, archive)});
}

fn zipAes(t: *T) !void {
    const archive = try t.p("secret.zip");
    try pack(t, &.{t.src}, archive, .Zip, "hunter2", false);
    const a = try open(t, archive, "hunter2");
    defer a.close();
    try unpack(t, a, try t.p("out-zipaes"), .Overwrite);
    try same(t, t.src, try t.p("out-zipaes\\src"));
    t.say("OK zip+aes ({d} bytes)", .{size(t, archive)});
}

fn emptyDirs(t: *T) !void {
    for ([_][]const u8{ "SevenZip", "Zip", "Tar" }) |k| {
        const d = try t.p(try t.ar.print("out-{s}\\src\\void\\deeper", .{k}));
        try t.must(dirExists(d), "{s}: the empty folder did not come back", .{k});
        const got = (try Io.Dir.cwd().statFile(t.io, d, .{})).mtime.toSeconds();
        try t.must(@abs(got - old_unix) <= 2, "{s}: the folder's time was not restored ({d})", .{ k, got });
    }
    t.say("OK empty_dirs (with their times)", .{});
}

fn appendCheck(t: *T) !void {
    for ([_][]const u8{ "SevenZip.7z", "Zip.zip", "Tar.tar", "Wim.wim" }) |name| {
        const archive = try fresh(t, name, try std.mem.concat(t.ar, u8, &.{ "append-", name }));
        const before = try count(t, archive, null);
        try appendTo(t, archive, null, &.{t.extra}, "src/sub/", .Overwrite);
        const after = try count(t, archive, null);
        try t.must(after == before + 1, "{s}: {d} entries before, {d} after", .{ name, before, after });
        const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "out-append-", name }));
        {
            const a = try open(t, archive, null);
            defer a.close();
            try unpack(t, a, dest, .Overwrite);
        }
        try same(t, t.src, try join(t.ar, &.{ dest, "src" }));
        try t.must(std.mem.eql(u8, try readFile(t, try join(t.ar, &.{ dest, "src", "sub", "extra.txt" })), "appended later"), "{s}: appended file differs", .{name});
    }
    // Header-encrypted 7z: the new file gets in, and the list stays behind the password.
    const secret = try fresh(t, "secret.7z", "append-secret.7z");
    const n = try count(t, secret, "hunter2");
    try appendTo(t, secret, "hunter2", &.{t.extra}, "", .Overwrite);
    try t.must(try count(t, secret, "hunter2") == n + 1, "encrypted 7z: count did not grow", .{});
    try t.must(!opens(t, secret), "encrypted 7z: the file list opened without a password after append", .{});
    {
        const a = try open(t, secret, "hunter2");
        defer a.close();
        for (a.items()) |it| if (std.mem.eql(u8, fspath.basename(it.path), "extra.txt"))
            try t.must(it.encrypted, "encrypted 7z: the appended file is not encrypted", .{});
    }
    try t.must(std.mem.find(u8, try readFile(t, secret), "appended later") == null, "encrypted 7z: the appended text is in the file in plain", .{});
    t.say("OK append (7z, zip, tar, wim, 7z with encrypted headers)", .{});
}

fn appendReplace(t: *T) !void {
    for ([_][]const u8{ "SevenZip.7z", "Zip.zip" }) |name| {
        const archive = try fresh(t, name, try std.mem.concat(t.ar, u8, &.{ "replace-", name }));
        const before = try count(t, archive, null);
        const file = try t.p("replace-src\\a.txt");
        try writeFile(t, file, "replaced");
        try appendTo(t, archive, null, &.{file}, "src/", .Overwrite);
        const after = try count(t, archive, null);
        try t.must(after == before, "{s}: {d} entries before, {d} after", .{ name, before, after });
        const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "out-replace-", name }));
        const got = try join(t.ar, &.{ dest, "src", "a.txt" });
        {
            const a = try open(t, archive, null);
            defer a.close();
            try unpack(t, a, dest, .Overwrite);
        }
        try t.must(std.mem.eql(u8, try readFile(t, got), "replaced"), "{s}: old content survived", .{name});
        try writeFile(t, file, "skipped");
        try appendTo(t, archive, null, &.{file}, "src/", .Skip);
        {
            const a = try open(t, archive, null);
            defer a.close();
            try unpack(t, a, dest, .Overwrite);
        }
        try t.must(std.mem.eql(u8, try readFile(t, got), "replaced"), "{s}: Skip replaced the file", .{name});
    }
    // Names that differ only in Cyrillic case are the same name (OrdinalIgnoreCase), in an append and among inputs.
    const low = try t.p("case-low\\файл.txt");
    const up = try t.p("case-up\\Файл.txt");
    try writeFile(t, low, "old");
    try writeFile(t, up, "new");
    const cy = try t.p("case.7z");
    try compress(t, &.{ low, up }, cy, .SevenZip, .{});
    try t.must(try count(t, cy, null) == 1, "two inputs differing only in Cyrillic case became two entries", .{});
    try appendTo(t, cy, null, &.{low}, "", .Skip);
    try t.must(try count(t, cy, null) == 1, "append of 'файл.txt' next to 'Файл.txt' was not a clash", .{});
    try appendTo(t, cy, null, &.{low}, "", .Overwrite);
    {
        const a = try open(t, cy, null);
        defer a.close();
        try t.must(a.items().len == 1, "Overwrite of a Cyrillic case clash left two entries", .{});
        const dest = try t.p("out-case");
        try unpack(t, a, dest, .Overwrite);
        try t.must(std.mem.eql(u8, try readFile(t, try join(t.ar, &.{ dest, "файл.txt" })), "old"), "Overwrite of a Cyrillic case clash kept the old data", .{});
    }
    t.say("OK append_replace", .{});
}

fn renameFile(t: *T) !void {
    for ([_]struct { []const u8, ?[]const u8 }{ .{ "SevenZip.7z", null }, .{ "Zip.zip", null }, .{ "secret.7z", "hunter2" } }) |c| {
        const name, const password = c;
        const archive = try fresh(t, name, try std.mem.concat(t.ar, u8, &.{ "renfile-", name }));
        const before = try count(t, archive, password);
        try engine.rename(t.gpa, t.io, try open(t, archive, password), "src/a.txt", "src/b renamed.txt", &t.diag);
        const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "out-renfile-", name }));
        {
            const a = try open(t, archive, password);
            defer a.close();
            try t.must(a.items().len == before, "{s}: entry count changed", .{name});
            try unpack(t, a, dest, .Overwrite);
        }
        try t.must(!fileExists(try join(t.ar, &.{ dest, "src", "a.txt" })), "{s}: the old name is still there", .{name});
        const orig = try readFile(t, try join(t.ar, &.{ t.src, "a.txt" }));
        try t.must(std.mem.eql(u8, orig, try readFile(t, try join(t.ar, &.{ dest, "src", "b renamed.txt" }))), "{s}: renamed file differs", .{name});
        try t.must(password == null or !opens(t, archive), "{s}: the file list opened without a password after rename", .{name});
    }
    t.say("OK rename_file", .{});
}

fn renameFolder(t: *T) !void {
    for ([_][]const u8{ "SevenZip.7z", "Zip.zip", "Tar.tar" }) |name| {
        const archive = try fresh(t, name, try std.mem.concat(t.ar, u8, &.{ "rendir-", name }));
        try engine.rename(t.gpa, t.io, try open(t, archive, null), "src/sub", "src/moved", &t.diag);
        const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "out-rendir-", name }));
        {
            const a = try open(t, archive, null);
            defer a.close();
            for (a.items()) |it| {
                const n = try engine.norm(t.ar, it.path);
                try t.must(!std.ascii.startsWithIgnoreCase(n, "src/sub"), "{s}: entries left under src/sub", .{name});
            }
            try unpack(t, a, dest, .Overwrite);
        }
        try same(t, try join(t.ar, &.{ t.src, "sub" }), try join(t.ar, &.{ dest, "src", "moved" }));
    }
    t.say("OK rename_folder", .{});
}

fn editGuard(t: *T) !void {
    // A failing edit must leave the archive as it was (SevenZipSharp deleted it in a finally block).
    const secret = try fresh(t, "secret.7z", "guard-secret.7z");
    var bytes = try readFile(t, secret);
    {
        const a = try open(t, secret, "hunter2");
        a.gpa.free(a.password.?);
        a.password = try a.gpa.dupe(u8, "WRONG"); // opened with the right one, edited with the wrong one
        const failed = if (engine.append(t.gpa, t.io, a, &.{t.extra}, "", .{}, .none, .always_overwrite, null)) false else |_| true;
        try t.must(failed, "append with a wrong password did not fail", .{});
    }
    try t.must(fileExists(secret) and std.mem.eql(u8, try readFile(t, secret), bytes), "a failed append changed the archive", .{});
    try t.must(!fileExists(try std.mem.concat(t.ar, u8, &.{ secret, ".makepack-new" })), "a failed append left its new file", .{});

    const seven = try fresh(t, "SevenZip.7z", "guard-cancel.7z");
    bytes = try readFile(t, seven);
    var c: Canceler = .{ .any = true };
    const r = engine.append(t.gpa, t.io, try open(t, seven, null), &.{t.src}, "copy/", .{}, c.progress(), .always_overwrite, null);
    try t.must(is(r, error.Canceled), "a cancelled append did not report the cancel", .{});
    try t.must(std.mem.eql(u8, try readFile(t, seven), bytes), "a cancelled append changed the archive", .{});
    try t.must(!fileExists(try std.mem.concat(t.ar, u8, &.{ seven, ".makepack~" })), "the safety link was left behind", .{});
    try t.must(!fileExists(try std.mem.concat(t.ar, u8, &.{ seven, ".makepack-new" })), "a cancelled append left its new file", .{});

    // The new archive is written but cannot replace the old one (another program holds it without delete sharing):
    // the edit fails in Windows' words, the archive is as it was, and the .makepack~ backup is still there.
    const locked = try fresh(t, "SevenZip.7z", "guard-locked.7z");
    bytes = try readFile(t, locked);
    const wl = try kit.win.toW(t.ar, locked);
    const h = w.CreateFileW(wl.ptr, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    try t.must(h != w.INVALID_HANDLE_VALUE, "could not hold the archive open", .{});
    const rl = engine.append(t.gpa, t.io, try open(t, locked, null), &.{t.extra}, "", .{}, .none, .always_overwrite, null);
    _ = w.CloseHandle(h);
    if (rl) |_| try t.must(false, "an append over a held archive reported success", .{}) else |e| {
        const msg = engine.friendly(e, null);
        try t.must(std.mem.find(u8, msg, @errorName(e)) == null, "the failure reads as a code name: {s}", .{msg});
    }
    try t.must(std.mem.eql(u8, try readFile(t, locked), bytes), "a failed replace changed the archive", .{});
    try t.must(!fileExists(try std.mem.concat(t.ar, u8, &.{ locked, ".makepack-new" })), "a failed replace left its new file", .{});
    const keep = try std.mem.concat(t.ar, u8, &.{ locked, ".makepack~" });
    try t.must(!fileExists(keep) or std.mem.eql(u8, try readFile(t, keep), bytes), "the .makepack~ backup differs from the archive", .{});
    t.say("OK edit_guard", .{});
}

fn deleteCheck(t: *T) !void {
    for ([_][]const u8{ "SevenZip.7z", "Zip.zip", "Tar.tar", "Wim.wim" }) |name| {
        const archive = try fresh(t, name, try std.mem.concat(t.ar, u8, &.{ "delete-", name }));
        const a = try open(t, archive, null);
        const before = a.items().len;
        const first = for (a.items()) |it| {
            if (!it.is_dir) break it.index;
        } else 0;
        try engine.delete(t.gpa, t.io, a, &.{first}, &t.diag);
        const after = try count(t, archive, null);
        try t.must(after == before - 1, "{s}: {d} entries before, {d} after", .{ name, before, after });
    }
    try refusesEdits(t, try t.p("TarGz.tar.gz"), null, "a nested tar.gz");
    t.say("OK delete (7z, zip, tar, wim)", .{});
}

/// Delete, Rename and Append all answer NotSupported (an SFX would lose its stub, a nested archive is a temp copy)
/// and leave the file as it was.
fn refusesEdits(t: *T, archive: []const u8, password: ?[]const u8, what: []const u8) !void {
    const bytes = try readFile(t, archive);
    try t.must(is(engine.delete(t.gpa, t.io, try open(t, archive, password), &.{0}, null), error.NotSupported), "{s}: delete was not refused", .{what});
    try t.must(is(engine.rename(t.gpa, t.io, try open(t, archive, password), "src", "moved", null), error.NotSupported), "{s}: rename was not refused", .{what});
    try t.must(is(engine.append(t.gpa, t.io, try open(t, archive, password), &.{t.extra}, "", .{}, .none, .always_overwrite, null), error.NotSupported), "{s}: append was not refused", .{what});
    try t.must(std.mem.eql(u8, try readFile(t, archive), bytes), "{s}: a refused edit changed the file", .{what});
}

fn checkCheck(t: *T) !void {
    const a = try open(t, try t.p("SevenZip.7z"), null);
    defer a.close();
    try t.must(try engine.testArchive(t.gpa, t.io, a, .none, &t.diag), "Check() said false", .{});
    t.say("OK check", .{});
}

fn gzipCheck(t: *T) !void {
    const archive = try t.p("a.txt.gz");
    const file = try join(t.ar, &.{ t.src, "a.txt" });
    try pack(t, &.{file}, archive, .GZip, null, false);
    const a = try open(t, archive, null);
    defer a.close();
    try t.must(!a.nested(), "a plain .gz must not be treated as a tarball", .{});
    const dest = try t.p("out-gz");
    try unpack(t, a, dest, .Overwrite);
    try t.must(std.mem.eql(u8, try readFile(t, file), try readFile(t, try join(t.ar, &.{ dest, "a.txt" }))), "a.txt differs", .{});
    t.say("OK GZip ({d} bytes)", .{size(t, archive)});
}

fn conflicts(t: *T) !void {
    const dest = try t.p("out-conflict");
    const a = try open(t, try t.p("Zip.zip"), null);
    defer a.close();
    try unpack(t, a, dest, .Overwrite);
    const marked = try join(t.ar, &.{ dest, "src", "a.txt" });
    try writeFile(t, marked, "marker");
    try unpack(t, a, dest, .Skip);
    try t.must(std.mem.eql(u8, try readFile(t, marked), "marker"), "Skip overwrote the file", .{});
    try unpack(t, a, dest, .Rename);
    try t.must(std.mem.eql(u8, try readFile(t, marked), "marker"), "Rename overwrote the file", .{});
    try t.must(fileExists(try join(t.ar, &.{ dest, "src", "a (2).txt" })), "Rename made no copy", .{});
    // Ask: the answer decides; no answer (the dialog closed) cancels and writes nothing over the file.
    const cancel_ask: engine.Conflict = .{ .ask = struct {
        fn f(_: ?*anyopaque, _: []const u8) ?OverwriteMode {
            return null;
        }
    }.f };
    const r = engine.extract(t.gpa, t.io, a, dest, null, .Ask, .none, cancel_ask, .Never, .{}, null);
    try t.must(is(r, error.Canceled), "Ask without an answer did not cancel", .{});
    try t.must(std.mem.eql(u8, try readFile(t, marked), "marker"), "Ask without an answer overwrote the file", .{});
    try engine.extract(t.gpa, t.io, a, dest, null, .Ask, .none, answer(.Skip), .Never, .{}, &t.diag);
    try t.must(std.mem.eql(u8, try readFile(t, marked), "marker"), "Ask answered Skip overwrote the file", .{});

    // The same past MAX_PATH: nothing may depend on the longPathAware manifest (off unless LongPathsEnabled=1).
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(t.ar, try t.p("out-conflict-long"));
    const seg: [100]u8 = @splat('d');
    for (0..3) |_| try long.print(t.ar, "\\{s}", .{&seg});
    const deep = long.items;
    try unpack(t, a, deep, .Overwrite);
    const deep_marked = try join(t.ar, &.{ deep, "src", "a.txt" });
    try t.must(deep_marked.len > 300 and fileExists(deep_marked), "a long path did not extract", .{});
    try writeFile(t, deep_marked, "marker");
    try unpack(t, a, deep, .Skip);
    try t.must(std.mem.eql(u8, try readFile(t, deep_marked), "marker"), "Skip overwrote a file on a long path", .{});
    try unpack(t, a, deep, .Rename);
    try t.must(fileExists(try join(t.ar, &.{ deep, "src", "a (2).txt" })), "Rename made no copy on a long path", .{});
    t.say("OK conflicts", .{});
}

fn probeCheck(t: *T) !void {
    const text = try t.p("plain.txt");
    var aw: Io.Writer.Allocating = .init(t.ar);
    for (0..300) |_| try aw.writer.writeAll("plain text, definitely not an archive\r\n");
    try writeFile(t, text, aw.written());
    try t.must(size(t, text) >= 10 * 1024, "the text fixture is smaller than 10 KB", .{});
    try t.must(engine.probe(t.io, text) == .not_archive, "10 KB of text was not called NotArchive", .{});
    const renamed = try t.p("renamed.7z");
    try writeFile(t, renamed, aw.written());
    try t.must(engine.probe(t.io, renamed) == .not_archive, "a text file named .7z was not called NotArchive", .{});

    const seven = try t.p("SevenZip.7z");
    try t.must(engine.probe(t.io, seven) == .archive, "an intact 7z was not called Archive", .{});
    try t.must(engine.probe(t.io, try t.p("Zip.zip")) == .archive, "an intact zip was not called Archive", .{});
    // Drag and drop: archives open, text and programs (even ones 7z.dll could read) are packed.
    try t.must(engine.looksLikeArchive(t.io, seven) and engine.looksLikeArchive(t.io, try t.p("TarGz.tar.gz")), "an archive does not look like one", .{});
    try t.must(!engine.looksLikeArchive(t.io, text) and !engine.looksLikeArchive(t.io, try ownExe(t)), "text or an exe looks like an archive", .{});
    const bytes = try readFile(t, seven);
    const cut = try t.p("cut.7z");
    try writeFile(t, cut, bytes[0 .. bytes.len * 6 / 10]);
    try t.must(engine.probe(t.io, cut) == .damaged, "a 7z truncated to 60% was not called Damaged", .{});
    const flipped = try t.ar.dupe(u8, bytes);
    flipped[32 + @as(usize, @intCast(std.mem.readInt(u64, flipped[12..20], .little)))] ^= 0xFF; // first byte of the next header
    const bad = try t.p("flipped.7z");
    try writeFile(t, bad, flipped);
    try t.must(engine.probe(t.io, bad) == .damaged, "a flipped next-header byte was not called Damaged", .{});

    const secret = try t.p("secret.7z");
    try t.must(engine.probe(t.io, secret) == .archive, "a header-encrypted 7z is intact and must probe as Archive", .{});
    try t.must(!opens(t, secret), "the header-encrypted 7z opened without a password", .{});
    // The two rar header parsers, on hand-built bytes - no rar fixture needed.
    try t.must(engine.rar4Encrypted(&.{ 0, 0, 0x73, 0x80, 0x00, 0x0D, 0x00 }), "rar4 MHD_PASSWORD was not seen", .{});
    try t.must(!engine.rar4Encrypted(&.{ 0, 0, 0x73, 0x00, 0x00, 0x0D, 0x00 }), "rar4 without the flag was called encrypted", .{});
    try t.must(!engine.rar4Encrypted(&.{ 0, 0, 0x74, 0x80, 0x00, 0x0D, 0x00 }), "rar4 flags read from a block that is not MAIN_HEAD", .{});
    try t.must(engine.rar5Encrypted(&.{ 0, 0, 0, 0, 0x0A, 0x04 }), "rar5 encryption header (type 4) was not seen", .{});
    try t.must(engine.rar5Encrypted(&.{ 0, 0, 0, 0, 0x80, 0x01, 0x04 }), "rar5 two-byte vint size was mis-parsed", .{});
    try t.must(!engine.rar5Encrypted(&.{ 0, 0, 0, 0, 0x0A, 0x01 }), "rar5 main header (type 1) was called encrypted", .{});
    t.say("OK probe", .{});
}

fn joinUsed(t: *T, used: []const []const u8) []const u8 {
    return std.mem.join(t.ar, ", ", used) catch "";
}

fn methods(t: *T) !void {
    for ([_]ArchiveKind{ .SevenZip, .Zip }) |k| for (engine.methodsFor(k)) |m| {
        const used = try roundTrip(t, k, t.text, .{ .method = m, .threads = 2 }, try t.ar.print("-{t}", .{m}));
        for (used) |u| try t.must(std.ascii.startsWithIgnoreCase(u, @tagName(m)), "{t} {t}: archive says '{s}'", .{ k, m, joinUsed(t, used) });
    };
    // Store ignores the coder knobs instead of tripping over them.
    _ = try roundTrip(t, .SevenZip, t.text, .{ .level = .None, .method = .Ppmd, .dictionary = 1 << 20 }, "-store");
}

fn blocks(t: *T, tag: []const u8) !u64 {
    const a = try open(t, try t.p(try t.ar.print("SevenZip{s}.7z", .{tag})), null);
    defer a.close();
    return a.x.props.blocks orelse {
        try t.must(false, "no block count", .{});
        return 0;
    };
}

fn advanced7z(t: *T) !void {
    var used = try roundTrip(t, .SevenZip, t.text, .{ .dictionary = 64 << 10, .filter = "off" }, "-d64k");
    for (used) |u| try t.must(std.mem.eql(u8, u, "LZMA2:16"), "d=64k f=off gave '{s}'", .{joinUsed(t, used)});
    used = try roundTrip(t, .SevenZip, t.text, .{ .filter = "BCJ2" }, "-bcj2");
    for (used) |u| try t.must(std.mem.find(u8, u, "BCJ2") != null, "f=BCJ2 gave '{s}'", .{joinUsed(t, used)});
    _ = try roundTrip(t, .SevenZip, t.text, .{ .solid = "off" }, "-nonsolid");
    const nonsolid = try blocks(t, "-nonsolid");
    try t.must(nonsolid >= 4, "s=off packed into {d} block(s)", .{nonsolid});
    const solid = try blocks(t, "-d64k");
    try t.must(solid == 1, "default solid packed into {d} blocks", .{solid});
    t.say("OK advanced_7z (dictionary, filter, solid)", .{});
}

fn rejected(t: *T, k: ArchiveKind, o: CompressOptions, what: []const u8) !void {
    const archive = try t.p(try std.mem.concat(t.ar, u8, &.{ "guard", types.kind(k).ext }));
    const r = engine.compress(t.gpa, t.io, &.{t.src}, archive, k, o, .none, null);
    try t.must(is(r, error.InvalidOption), "{s} was accepted", .{what});
    try t.must(!fileExists(archive), "{s} left a file behind", .{what});
}

fn advancedGuard(t: *T) !void {
    try rejected(t, .Zip, .{ .solid = "on" }, "zip + solid"); // 7z.dll would write a broken zip
    try rejected(t, .SevenZip, .{ .method = .Ppmd, .dictionary = 1 << 20 }, "PPMd + dictionary");
    try rejected(t, .Zip, .{ .method = .Lzma2 }, "zip + LZMA2");
    try rejected(t, .Tar, .{ .threads = 2 }, "tar + threads");
    // gz/bz2/xz hold one file; a dictionary the machine cannot afford is refused before 7z.dll runs out of memory.
    const two = try t.p("two.gz");
    const r1 = engine.compress(t.gpa, t.io, &.{ t.extra, try join(t.ar, &.{ t.src, "a.txt" }) }, two, .GZip, .{}, .none, null);
    try t.must(is(r1, error.SingleFileOnly) and !fileExists(two), "two files into a .gz were not refused", .{});
    const huge = try t.p("huge.bin"); // 2 TB, sparse: nothing on disk
    {
        var f = try Io.Dir.cwd().createFile(t.io, huge, .{});
        defer f.close(t.io);
        var got: w.DWORD = 0;
        try t.must(w.DeviceIoControl(f.handle, 0x000900C4, null, 0, null, 0, &got, null) != 0, "FSCTL_SET_SPARSE failed", .{});
        try f.setLength(t.io, 1 << 41);
    }
    defer Io.Dir.cwd().deleteFile(t.io, huge) catch {};
    const huge_arc = try t.p("huge.7z");
    var d: engine.Diag = .{};
    const r2 = engine.compress(t.gpa, t.io, &.{huge}, huge_arc, .SevenZip, .{ .dictionary = 1 << 40 }, .none, &d);
    try t.must(is(r2, error.DictionaryTooBig) and d.text() != null and !fileExists(huge_arc), "a 1 TB dictionary over 2 TB was not refused up front", .{});
    const G: i64 = 1 << 30;
    const big = engine.dictionaryFits(.{ .dictionary = G }, 10 * G, 8 * G);
    try t.must(!big.fits and big.need > 8 * G, "a 1 GB dictionary over 10 GB of input fit in 8 GB of RAM", .{});
    try t.must(engine.dictionaryFits(.{ .dictionary = G }, 1 << 20, 8 * G).fits, "a 1 GB dictionary over 1 MB of input (shrunk by 7-Zip) did not fit", .{});
    try t.must(engine.dictionaryFits(.{}, 100 * G, 1).fits, "the default dictionary was checked at all", .{});
    var b: [32]u8 = undefined;
    try t.must(std.mem.eql(u8, engine.size7z(&b, 64 << 10), "64k") and std.mem.eql(u8, engine.size7z(&b, 3 << 20), "3m") and
        std.mem.eql(u8, engine.size7z(&b, 1000), "1000b"), "7-Zip size syntax", .{});
    t.say("OK advanced_guard", .{});
}

fn volumes(t: *T) !void {
    const vol: i64 = 300 << 10;
    for ([_]ArchiveKind{ .SevenZip, .Zip, .TarGz }) |k| {
        const archive = try t.p(try std.mem.concat(t.ar, u8, &.{ "vol", types.kind(k).ext }));
        const stale = try engine.part(t.ar, archive, 9);
        try writeFile(t, stale, "stale part of an older set");
        try compress(t, &.{t.src}, archive, k, .{ .volume_size = vol });
        const parts = try namesLike(t, t.root, try std.mem.concat(t.ar, u8, &.{ fspath.basename(archive), "." }));
        var small = true;
        for (parts) |p| small = small and size(t, p) <= vol;
        try t.must(parts.len >= 3 and small, "{t}: {d} parts", .{ k, parts.len });
        try t.must(!fileExists(archive) and !fileExists(stale), "{t}: a whole file or the stale .009 is left", .{k});
        const a = try open(t, try engine.part(t.ar, archive, 1), null);
        defer a.close();
        const dest = try t.p(try t.ar.print("out-vol-{t}", .{k}));
        try unpack(t, a, dest, .Overwrite);
        try same(t, t.src, try join(t.ar, &.{ dest, "src" }));
    }
    var c: Canceler = .{ .any = true };
    const r = engine.compress(t.gpa, t.io, &.{t.src}, try t.p("vol-cancel.7z"), .SevenZip, .{ .volume_size = vol }, c.progress(), null);
    try t.must(is(r, error.Canceled), "cancel was not reported", .{});
    try t.must((try namesLike(t, t.root, "vol-cancel.7z")).len == 0, "cancel left parts or the temp file behind", .{});
    for ([_]struct { []const u8, ?i64 }{
        .{ "", 0 },            .{ "100 MB", 100 << 20 }, .{ "700 MB (CD)", 700 << 20 },
        .{ "1,5 ГБ", 3 << 29 },
        .{ "1.5g", 3 << 29 },  .{ "650m", 650 << 20 },
        .{ "64 кб", 64 << 10 },
        .{ "250000", 250000 }, .{ "abc", null },         .{ "10 parsecs", null },
        .{ "0", null },
    }) |c2| try t.must(engine.parseSize(c2[0]) == c2[1], "ParseSize('{s}') = {?d}, expected {?d}", .{ c2[0], engine.parseSize(c2[0]), c2[1] });
    t.say("OK volumes (7z, zip, tar.gz, cancel, sizes)", .{});
}

fn sources(t: *T, name: []const u8) ![]const u8 {
    const dir = try t.p(name);
    var aw: Io.Writer.Allocating = .init(t.ar);
    for (0..5000) |_| try aw.writer.writeAll("after-actions ");
    try writeFile(t, try join(t.ar, &.{ dir, "one.txt" }), aw.written());
    try writeFile(t, try join(t.ar, &.{ dir, "inner", "two.txt" }), "two");
    return dir;
}

fn both(volume: i64, password: ?[]const u8) CompressOptions {
    return .{ .test_after = true, .delete_sources = true, .volume_size = volume, .password = password };
}

fn afterActions(t: *T) !void {
    // Happy path: tested, then the sources are gone (to the Recycle Bin).
    const ok = try sources(t, "MakePack-selftest-recycled");
    const ok_arc = try t.p("after-ok.7z");
    try compress(t, &.{ok}, ok_arc, .SevenZip, both(0, null));
    try t.must(fileExists(ok_arc) and !dirExists(ok), "after a passed test the sources should be gone and the archive there", .{});
    try t.must(try fromRecycleBin(t) >= 1, "the deleted sources are not in the Recycle Bin", .{});

    // Test after a volume set with a password: open has to glue the parts and know the password.
    const vol = try sources(t, "MakePack-selftest-recycled-vol");
    const vol_arc = try t.p("after-vol.7z");
    try compress(t, &.{vol}, vol_arc, .SevenZip, both(128, "hunter2"));
    try t.must(fileExists(try engine.part(t.ar, vol_arc, 2)), "volumes + password + test: no second part", .{});
    try t.must(!dirExists(vol), "volumes + password + test: the sources are still there", .{});
    _ = try fromRecycleBin(t);

    // A damaged archive: the test fails, the sources stay.
    const bad = try sources(t, "after-bad");
    hook_io = t.io;
    engine.before_test_hook = damagePacked;
    const failed = engine.compress(t.gpa, t.io, &.{bad}, try t.p("after-bad.7z"), .SevenZip, both(0, null), .none, null);
    engine.before_test_hook = null;
    try t.must(is(failed, error.TestAfterFailed), "a damaged archive passed the test (or failed otherwise)", .{});
    try t.must(fileExists(try join(t.ar, &.{ bad, "inner", "two.txt" })), "a failed test still deleted the sources", .{});

    // Cancelled while packing: no archive, sources untouched.
    const cancelled = try sources(t, "after-cancel");
    var c: Canceler = .{ .any = true };
    _ = engine.compress(t.gpa, t.io, &.{cancelled}, try t.p("after-cancel.7z"), .SevenZip, both(0, null), c.progress(), null) catch {};
    try t.must(fileExists(try join(t.ar, &.{ cancelled, "one.txt" })), "cancel deleted the sources", .{});

    // The archive inside a folder that is about to be recycled: refused before anything is written.
    const home = try sources(t, "after-inside");
    const inside = try join(t.ar, &.{ home, "inner", "self.7z" });
    const r = engine.compress(t.gpa, t.io, &.{home}, inside, .SevenZip, both(0, null), .none, null);
    try t.must(is(r, error.ArchiveInsideSources) and !fileExists(inside) and dirExists(home), "an archive inside a source folder was not refused", .{});
    // A file packed into itself: same refusal (it would be recycled right after being written).
    const self_arc = try fresh(t, "SevenZip.7z", "after-self.7z");
    const self_bytes = try readFile(t, self_arc);
    const rs = engine.compress(t.gpa, t.io, &.{self_arc}, self_arc, .SevenZip, both(0, null), .none, null);
    try t.must(is(rs, error.ArchiveInsideSources) and std.mem.eql(u8, try readFile(t, self_arc), self_bytes), "x.7z packed into x.7z with delete-sources was not refused", .{});

    // Shift+Del: gone for good, nothing of it in the Recycle Bin.
    const nuked = try t.p("after-nuked.txt");
    try writeFile(t, nuked, "permanently deleted");
    try engine.recycle(t.gpa, &.{nuked}, false, &t.diag);
    try t.must(!fileExists(nuked) and try fromRecycleBin(t) == 0, "recycle(undo=false) did not delete for good", .{});
    t.say("OK after_actions (test, recycle, damaged, cancel, inside)", .{});
}

fn planNames(t: *T, sep: []const u8, plan: []const engine.Planned) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (plan) |x| {
        const rel = try t.ar.dupe(u8, x.output[sep.len + 1 ..]);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        try names.append(t.ar, rel);
    }
    return std.mem.join(t.ar, ", ", names.items);
}

fn separate(t: *T) !void {
    const sep = try t.p("sep");
    for ([_][]const u8{ "photos\\p.jpg", "a.txt", "a.doc", "b.txt", "other\\a.txt" }) |f|
        try writeFile(t, try join(t.ar, &.{ sep, f }), try std.mem.concat(t.ar, u8, &.{ "content of ", f }));
    const In = struct {
        fn f(x: *T, s: []const u8, rel: []const u8) []const u8 {
            return join(x.ar, &.{ s, rel }) catch "";
        }
    }.f;
    var plan = try engine.planSeparate(t.ar, t.io, &.{ In(t, sep, "photos"), In(t, sep, "a.txt"), In(t, sep, "a.doc"), In(t, sep, "b.txt") }, ".7z", null);
    var names = try planNames(t, sep, plan);
    try t.must(std.mem.eql(u8, names, "photos.7z, a.txt.7z, a.doc.7z, b.7z"), "plan: {s}", .{names});
    // Into one folder: the two a.txt files clash even by whole name.
    const into = In(t, sep, "into");
    try Io.Dir.cwd().createDirPath(t.io, into);
    plan = try engine.planSeparate(t.ar, t.io, &.{ In(t, sep, "a.txt"), In(t, sep, "other\\a.txt"), In(t, sep, "b.txt") }, ".zip", into);
    names = try planNames(t, sep, plan);
    try t.must(std.mem.eql(u8, names, "into/a.txt.zip, into/a.txt (2).zip, into/b.zip"), "plan into a folder: {s}", .{names});

    // The series: one archive per input, each with its own content.
    plan = try engine.planSeparate(t.ar, t.io, &.{ In(t, sep, "photos"), In(t, sep, "a.txt"), In(t, sep, "b.txt") }, ".7z", null);
    try engine.compressEach(t.gpa, t.io, plan, .SevenZip, .{}, .none, &t.diag);
    for (plan) |x| {
        const a = try open(t, x.output, null);
        defer a.close();
        const want = if (dirExists(x.input)) "p.jpg" else fspath.basename(x.input);
        var files: usize = 0;
        for (a.items()) |it| if (!it.is_dir) {
            files += 1;
            try t.must(std.mem.eql(u8, fspath.basename(it.path), want), "{s} holds {s}", .{ fspath.basename(x.output), it.path });
        };
        try t.must(files == 1, "{s} holds {d} files", .{ fspath.basename(x.output), files });
    }

    // Cancel in the middle of the second archive: the first stays, the second and third never appear.
    const series = try t.p("series");
    try Io.Dir.cwd().createDirPath(t.io, series);
    const cancel_plan = [_]engine.Planned{
        .{ .input = In(t, sep, "a.txt"), .output = In(t, series, "1.7z") },
        .{ .input = t.text, .output = In(t, series, "2.7z") },
        .{ .input = In(t, sep, "b.txt"), .output = In(t, series, "3.7z") },
    };
    var c: Canceler = .{ .past = 40 };
    _ = engine.compressEach(t.gpa, t.io, &cancel_plan, .SevenZip, .{ .solid = "off" }, c.progress(), null) catch {};
    try t.must(fileExists(cancel_plan[0].output), "cancel removed an archive that was already finished", .{});
    try t.must(!fileExists(cancel_plan[1].output), "cancel left the unfinished archive behind", .{});
    try t.must(!fileExists(cancel_plan[2].output), "the series went on after cancel", .{});
    t.say("OK separate (names, series, cancel)", .{});
}

fn sfx(t: *T) !void {
    const exe = try t.p("self.exe");
    try compress(t, &.{t.src}, exe, .SevenZip, .{ .sfx = true, .test_after = true });
    const module = try readFile(t, try engine.sfxModule(t.ar));
    try t.must(std.mem.startsWith(u8, try readFile(t, exe), module), "the exe does not start with 7z.sfx", .{});
    try t.must(!fileExists(try std.mem.concat(t.ar, u8, &.{ exe, ".makepack-tmp" })) and !fileExists(try std.mem.concat(t.ar, u8, &.{ exe, ".makepack-sfx" })), "a temp file was left behind", .{});
    {
        const a = try open(t, exe, null);
        defer a.close();
        try t.must(!engine.canDelete(t.io, a), "an SFX exe is offered for in-place editing (that would cut its stub off)", .{});
        const dest = try t.p("out-sfx-open");
        try unpack(t, a, dest, .Overwrite);
        try same(t, t.src, try join(t.ar, &.{ dest, "src" }));
    }
    try refusesEdits(t, exe, null, "an SFX");
    // The real thing: run it. 7z.sfx takes -y (no questions) and -o<folder>.
    const ran = try t.p("out-sfx-run");
    const code = try runHidden(t, exe, try t.ar.print("-y \"-o{s}\"", .{ran}), 60000);
    try t.must(code != null, "the SFX did not finish within 60 s", .{});
    try t.must(code.? == 0, "the SFX exited with {d}", .{code.?});
    try same(t, t.src, try join(t.ar, &.{ ran, "src" }));

    // Encrypted names: the file list is behind the password, so MakePack must ask instead of failing.
    const locked = try t.p("locked.exe");
    try compress(t, &.{t.src}, locked, .SevenZip, .{ .password = "hunter2", .encrypt_headers = true, .sfx = true });
    try t.must(engine.canEncryptHeaders(t.io, locked), "an SFX with encrypted names is not recognised as password-protected", .{});
    // Our own exe carries Assoc's empty 7z (a valid start header, no file list) as a constant: still a plain exe.
    try t.must(!engine.canEncryptHeaders(t.io, try ownExe(t)), "a plain exe was taken for a password-protected SFX", .{});
    {
        const a = try open(t, locked, "hunter2");
        defer a.close();
        try t.must(a.items().len > 4, "the encrypted SFX did not list with its password", .{});
    }
    for ([_]struct { ArchiveKind, CompressOptions, []const u8 }{
        .{ .Zip, .{ .sfx = true }, "zip SFX" },
        .{ .SevenZip, .{ .sfx = true, .volume_size = 1 << 20 }, "SFX in volumes" },
    }) |c| {
        const bad = try t.p("bad-sfx.exe");
        const r = engine.compress(t.gpa, t.io, &.{t.src}, bad, c[0], c[1], .none, null);
        try t.must(is(r, error.InvalidOption) and !fileExists(bad), "{s} was not refused up front", .{c[2]});
    }
    t.say("OK sfx (glue, open, read-only, run, encrypted, refused)", .{});
}

fn zipMethods(t: *T, zip: []const u8) ![]const []const u8 {
    const a = try open(t, zip, "hunter2");
    defer a.close();
    var list: std.ArrayList([]const u8) = .empty;
    for (a.items()) |it| if (it.size > 0) try list.append(t.ar, try t.ar.dupe(u8, it.method));
    return list.items;
}

fn zipCrypto(t: *T) !void {
    const legacy = try t.p("legacy.zip");
    try compress(t, &.{t.text}, legacy, .Zip, .{ .password = "hunter2", .zip_crypto = true });
    var used = try zipMethods(t, legacy);
    for (used) |m| try t.must(std.mem.startsWith(u8, m, "ZipCrypto"), "ZipCrypto zip says {s}", .{joinUsed(t, used)});
    {
        const a = try open(t, legacy, "hunter2");
        defer a.close();
        const dest = try t.p("out-zipcrypto");
        try unpack(t, a, dest, .Overwrite);
        try same(t, t.text, try join(t.ar, &.{ dest, "text" }));
    }
    const aes = try t.p("aes.zip");
    try compress(t, &.{t.text}, aes, .Zip, .{ .password = "hunter2" });
    used = try zipMethods(t, aes);
    for (used) |m| try t.must(std.mem.startsWith(u8, m, "AES-256"), "the default zip encryption says {s}", .{joinUsed(t, used)});
    const zc = try t.p("zc.7z");
    const r = engine.compress(t.gpa, t.io, &.{t.text}, zc, .SevenZip, .{ .password = "x", .zip_crypto = true }, .none, null);
    try t.must(is(r, error.InvalidOption) and !fileExists(zc), "ZipCrypto on a 7z was not refused up front", .{});
    t.say("OK zipcrypto (method, round trip, AES default, refused for 7z)", .{});
}

fn settingsCheck(t: *T) !void {
    const path = try t.p("cfg\\settings.json");
    {
        var l = settings.load(t.gpa, t.io, path);
        defer l.deinit();
        try t.must(l.v.Format == .SevenZip, "a missing file did not give defaults", .{});
    }
    const s: settings.Settings = .{ .Format = .TarXz, .Level = .Ultra, .ArchiveFolder = "D:\\Архіви" };
    try settings.saveOrFail(&s, t.gpa, t.io, path);
    {
        var back = settings.load(t.gpa, t.io, path);
        defer back.deinit();
        try t.must(back.v.Format == .TarXz and back.v.Level == .Ultra and std.mem.eql(u8, back.v.ArchiveFolder orelse "", "D:\\Архіви"), "settings did not survive a save/load round trip", .{});
    }
    try t.must((try namesLike(t, try t.p("cfg"), "")).len == 1, "the temp file of the atomic save was left behind", .{});
    for ([_][]const u8{ "{broken", "", "null", "{\"Format\":\"NoSuchKind\"}", "[1,2]" }) |junk| {
        try writeFile(t, path, junk);
        var d = settings.load(t.gpa, t.io, path);
        defer d.deinit();
        try t.must(d.v.Format == .SevenZip and d.v.ArchiveFolder == null, "'{s}' did not fall back to defaults", .{junk});
    }
    t.say("OK settings", .{});
}

const zone_text = "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=https://example.test/payload.7z\r\n";

fn writeZone(t: *T, file: []const u8, zone: []const u8) !void {
    const wp = try kit.win.toW(t.ar, try std.mem.concat(t.ar, u8, &.{ file, ":Zone.Identifier" }));
    const h = w.CreateFileW(wp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.Unexpected;
    defer _ = w.CloseHandle(h);
    var put: w.DWORD = 0;
    if (w.WriteFile(h, zone.ptr, @intCast(zone.len), &put, null) == 0) return error.Unexpected;
}

/// The files under motw\out-<tag>\payload that came out carrying the archive's mark.
fn markedFiles(t: *T, archive: []const u8, policy: types.MotwPolicy, tag: []const u8, mode: OverwriteMode) ![]const u8 {
    const dest = try t.p(try std.mem.concat(t.ar, u8, &.{ "motw\\out-", tag }));
    {
        const a = try open(t, archive, null);
        defer a.close();
        const ask: engine.Conflict = switch (mode) {
            .Rename => answer(.Rename),
            else => answer(.Overwrite),
        };
        try engine.extract(t.gpa, t.io, a, dest, null, mode, .none, ask, policy, .{}, &t.diag);
    }
    const payload = try join(t.ar, &.{ dest, "payload" });
    var got: std.ArrayList([]const u8) = .empty;
    for (try filesUnder(t, payload)) |rel| {
        const z = engine.zoneOf(t.ar, t.io, try join(t.ar, &.{ payload, rel })) orelse continue;
        if (std.mem.eql(u8, z, zone_text)) try got.append(t.ar, rel);
    }
    return std.mem.join(t.ar, ",", got.items);
}

fn motw(t: *T) !void {
    const dir = try t.p("motw\\payload");
    for ([_][]const u8{ "a.exe", "b.docx", "c.txt", "d.zip", "sub\\e.ps1" }) |f| try writeFile(t, try join(t.ar, &.{ dir, f }), try std.mem.concat(t.ar, u8, &.{ "content of ", f }));
    const marked_arc = try t.p("motw\\marked.7z");
    const clean = try t.p("motw\\clean.7z");
    for ([_][]const u8{ marked_arc, clean }) |arc| try compress(t, &.{dir}, arc, .SevenZip, .{});
    try writeZone(t, marked_arc, zone_text); // what a browser leaves on a download
    try t.must(std.mem.eql(u8, engine.zoneOf(t.ar, t.io, marked_arc) orelse "", zone_text) and engine.zoneOf(t.ar, t.io, clean) == null, "the fixture's Zone.Identifier", .{});

    var got = try markedFiles(t, marked_arc, .Risky, "risky", .Overwrite);
    try t.must(std.mem.eql(u8, got, "a.exe,b.docx,d.zip,sub/e.ps1"), "Risky marked: {s}", .{got});
    got = try markedFiles(t, marked_arc, .All, "all", .Overwrite);
    try t.must(std.mem.eql(u8, got, "a.exe,b.docx,c.txt,d.zip,sub/e.ps1"), "All marked: {s}", .{got});
    got = try markedFiles(t, marked_arc, .Never, "never", .Overwrite);
    try t.must(got.len == 0, "Never still marked something: {s}", .{got});
    got = try markedFiles(t, clean, .All, "clean", .Overwrite);
    try t.must(got.len == 0, "an archive without a mark passed one on: {s}", .{got});
    // Rename on clash: the renamed copy is the one written, so it is the one marked.
    _ = try markedFiles(t, marked_arc, .Risky, "rename", .Overwrite);
    got = try markedFiles(t, marked_arc, .Risky, "rename", .Rename);
    try t.must(std.mem.find(u8, got, "a (2).exe") != null, "a file renamed on a clash was not marked: {s}", .{got});
    // A split set carries the mark on its first part, the way the browser leaves it.
    const parts = try t.p("motw\\parts.7z");
    try compress(t, &.{dir}, parts, .SevenZip, .{ .level = .None, .volume_size = 512 });
    const first = try engine.part(t.ar, parts, 1);
    try writeZone(t, first, zone_text);
    got = try markedFiles(t, first, .Risky, "split", .Overwrite);
    try t.must(std.mem.eql(u8, got, "a.exe,b.docx,d.zip,sub/e.ps1"), "a marked .001 set did not pass the mark on: {s}", .{got});
    // An edit in place writes a new file: the archive's own mark must come along.
    const edited = try fresh(t, "motw\\clean.7z", "motw\\edited.7z");
    try writeZone(t, edited, zone_text);
    try appendTo(t, edited, null, &.{t.extra}, "", .Overwrite);
    try t.must(std.mem.eql(u8, engine.zoneOf(t.ar, t.io, edited) orelse "", zone_text), "an append dropped the archive's own mark", .{});
    t.say("OK motw (risky, all, never, unmarked, rename, split)", .{});
}

fn xo(t: *T, archive: []const u8, dest: []const u8, o: types.ExtractOptions) !void {
    const a = try open(t, archive, null);
    defer a.close();
    try engine.extract(t.gpa, t.io, a, dest, null, .Overwrite, .none, .always_overwrite, .Never, o, &t.diag);
}

fn extractOptions(t: *T) !void {
    const home = try t.p("xo");
    const arc = try join(t.ar, &.{ home, "src.7z" });
    try compress(t, &.{t.src}, arc, .SevenZip, .{});

    // No folders: every file lands in the destination itself.
    const flat = try join(t.ar, &.{ home, "flat" });
    try xo(t, arc, flat, .{ .no_paths = true });
    var got_names: std.ArrayList([]const u8) = .empty;
    for (try filesUnder(t, flat)) |f| try got_names.append(t.ar, f);
    var want_names: std.ArrayList([]const u8) = .empty;
    for (try filesUnder(t, t.src)) |f| try want_names.append(t.ar, fspath.basename(f));
    std.mem.sort([]const u8, want_names.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f);
    const got = try std.mem.join(t.ar, ", ", got_names.items);
    try t.must(std.mem.eql(u8, got, try std.mem.join(t.ar, ", ", want_names.items)), "no-paths gave {s}", .{got});

    // Update modes: a file newer on disk stays, an older one is refreshed, a missing one depends on the mode.
    const upd = try join(t.ar, &.{ home, "upd" });
    try xo(t, arc, upd, .{});
    const root2 = try join(t.ar, &.{ upd, "src" });
    const pa = try join(t.ar, &.{ root2, "a.txt" });
    const pe = try join(t.ar, &.{ root2, "empty.txt" });
    const pb = try join(t.ar, &.{ root2, "sub", "b.bin" });
    for ([_]types.UpdateMode{ .Newer, .Existing }) |mode| {
        try writeFile(t, pa, "edited later");
        try setMtime(pa, now() + 24 * 3600 * 10_000_000);
        try writeFile(t, pe, "stale copy");
        try setMtime(pe, 126227808000000000); // 2001-01-01
        Io.Dir.cwd().deleteFile(t.io, pb) catch {};
        try xo(t, arc, upd, .{ .update = mode });
        try t.must(std.mem.eql(u8, try readFile(t, pa), "edited later"), "{t} overwrote a file that is newer on disk", .{mode});
        try t.must(size(t, pe) == 0, "{t} did not refresh an older file", .{mode});
        try t.must(fileExists(pb) == (mode == .Newer), "{t}: sub\\b.bin on disk is {}", .{ mode, fileExists(pb) });
    }

    // Broken data: by default the half-written file goes, with Keep broken files it stays.
    const bad = try join(t.ar, &.{ home, "bad" });
    var prng: std.Random.DefaultPrng = .init(9);
    for ([_][]const u8{ "a.bin", "b.bin" }) |n| try noise(t, try join(t.ar, &.{ bad, n }), 200_000, prng.random());
    const broken = try join(t.ar, &.{ home, "broken.7z" });
    try compress(t, &.{ try join(t.ar, &.{ bad, "a.bin" }), try join(t.ar, &.{ bad, "b.bin" }) }, broken, .SevenZip, .{ .level = .None, .solid = "off" });
    const bytes = try readFile(t, broken);
    for (300_000..300_064) |i| bytes[i] ^= 0xFF; // inside b.bin's stored data
    try writeFile(t, broken, bytes);
    for ([_]bool{ false, true }) |keep| {
        const dest = try join(t.ar, &.{ home, if (keep) "broken-True" else "broken-False" });
        const r = xo(t, broken, dest, .{ .keep_broken = keep });
        try t.must(is(r, error.Damaged), "a CRC error went unreported", .{});
        try t.must(fileExists(try join(t.ar, &.{ dest, "a.bin" })), "the intact file before the broken one is gone", .{});
        try t.must(fileExists(try join(t.ar, &.{ dest, "b.bin" })) == keep, "{s}", .{if (keep) "Keep broken files dropped it" else "a broken file was left on disk"});
    }

    // Zip-slip in no-paths and update modes too: nothing lands outside the destination.
    const slip = try join(t.ar, &.{ home, "slip.zip" });
    try writeZip(t, slip, &.{ .{ "ok.txt", "fine" }, .{ "../escaped.txt", "evil" } });
    for ([_]types.ExtractOptions{ .{ .no_paths = true }, .{ .update = .Newer } }) |o| {
        const dest = try join(t.ar, &.{ home, "slip-out", if (o.no_paths) "flat" else "newer" });
        xo(t, slip, dest, o) catch |e| if (e != error.UnsafeEntriesSkipped) return e;
        try t.must(!fileExists(try join(t.ar, &.{ home, "slip-out", "escaped.txt" })) and fileExists(try join(t.ar, &.{ dest, "ok.txt" })), "zip-slip got through with no_paths={}", .{o.no_paths});
    }
    // The other spellings of "outside": backslashes, a climb from a subfolder, "...", an absolute path. Every target
    // lies inside this run's folder, so a miss cannot write anywhere else. (UNC and "C:x" only in engine's unit test.)
    const slip2 = try join(t.ar, &.{ home, "slip2.zip" });
    const abs = try join(t.ar, &.{ home, "slip2-abs.txt" });
    try writeZip(t, slip2, &.{ .{ "ok.txt", "fine" }, .{ "..\\bs.txt", "evil" }, .{ "a/../../dd.txt", "evil" }, .{ "...\\dots.txt", "evil" }, .{ abs, "evil" } });
    const in2 = try join(t.ar, &.{ home, "slip2-out", "in" });
    const r2 = xo(t, slip2, in2, .{});
    try t.must(is(r2, error.UnsafeEntriesSkipped), "the unsafe zip was not reported as a warning", .{});
    for ([_][]const u8{ "bs.txt", "dd.txt", "dots.txt" }) |n|
        try t.must(!fileExists(try join(t.ar, &.{ home, "slip2-out", n })) and !fileExists(try join(t.ar, &.{ in2, n })), "zip-slip: {s} was written", .{n});
    try t.must(!fileExists(abs) and fileExists(try join(t.ar, &.{ in2, "ok.txt" })), "zip-slip: an absolute path got through", .{});

    // Device names (NUL opens the device even inside a folder on Windows 11): extracted with "_" in front, as 7-Zip.
    const dev = try join(t.ar, &.{ home, "devices.zip" });
    try writeZip(t, dev, &.{ .{ "NUL", "n" }, .{ "sub/con.txt", "c" }, .{ "Com1.log", "1" } });
    const dev_out = try join(t.ar, &.{ home, "devices-out" });
    try xo(t, dev, dev_out, .{});
    for ([_][]const u8{ "_NUL", "sub\\_con.txt", "_Com1.log" }) |n|
        try t.must(fileExists(try join(t.ar, &.{ dev_out, n })), "device name: {s} missing", .{n});

    // Deleting after extraction: a .001 set goes to the Recycle Bin whole.
    const set = try join(t.ar, &.{ home, "set.7z" });
    try compress(t, &.{t.src}, set, .SevenZip, .{ .level = .None, .volume_size = 300 << 10 });
    try t.must(fileExists(try engine.part(t.ar, set, 3)), "the volume fixture", .{});
    try engine.recycleArchive(t.gpa, t.io, try engine.part(t.ar, set, 1), &t.diag);
    try t.must((try namesLike(t, home, "set.7z.")).len == 0, "parts left after recycling the set", .{});
    _ = try fromRecycleBin(t);
    t.say("OK extract_options (no paths, newer, existing, broken, zip-slip, device names, recycle set)", .{});
}

fn shellNew(t: *T) !void {
    // Explorer's New > MakePack archive writes these 32 bytes as "New MakePack archive.7z".
    const archive = try t.p("New archive.7z");
    try writeFile(t, archive, &assoc.empty_seven_zip);
    try t.must(engine.probe(t.io, archive) == .archive, "the empty 7z does not probe as an archive", .{});
    try t.must(try count(t, archive, null) == 0, "the empty 7z is not empty", .{});
    try appendTo(t, archive, null, &.{try join(t.ar, &.{ t.src, "a.txt" })}, "", .Overwrite);
    try t.must(try count(t, archive, null) == 1, "a file dropped into the new archive is not there", .{});
    t.say("OK shellnew (empty 7z opens, takes files)", .{});
}

fn label(s: S.Str) []const u8 {
    return std.mem.trimEnd(u8, s.get(), ":");
}

fn rows(t: *T, archive: []const u8, password: ?[]const u8) !std.StringHashMapUnmanaged([]const u8) {
    const a = try open(t, archive, password);
    defer a.close();
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try engine.describe(t.ar, t.io, a)) |r| try map.put(t.ar, r.label, r.value);
    return map;
}

fn nice(t: *T, n: anytype) []const u8 {
    var b: [32]u8 = undefined;
    return t.ar.dupe(u8, engine.niceSize(&b, @intCast(n))) catch "";
}

fn info(t: *T) !void {
    const home = try t.p("info");
    const Make = struct {
        fn f(x: *T, h: []const u8, name: []const u8, k: ArchiveKind, o: CompressOptions) ![]const u8 {
            const path = try join(x.ar, &.{ h, name });
            try compress(x, &.{x.text}, path, k, o);
            return path;
        }
    }.f;
    var text_bytes: u64 = 0;
    for (try filesUnder(t, t.text)) |f| text_bytes += size(t, try join(t.ar, &.{ t.text, f }));

    const seven = try Make(t, home, "d64k.7z", .SevenZip, .{ .dictionary = 64 << 10, .filter = "off" });
    var r = try rows(t, seven, null);
    const m = r.get(label(S.method)) orelse "";
    try t.must(std.mem.eql(u8, m, "LZMA2:16"), "7z method: {s}", .{m});
    try t.must(std.mem.eql(u8, r.get(label(S.dictionary)) orelse "", nice(t, 64 << 10)), "7z dictionary: {s}", .{r.get(label(S.dictionary)) orelse "-"});
    try t.must(std.mem.startsWith(u8, r.get(S.solid.get()) orelse "", S.yes.get()), "7z solid: {s}", .{r.get(S.solid.get()) orelse "-"});
    try t.must(std.mem.eql(u8, r.get(S.files.get()).?, "4") and std.mem.eql(u8, r.get(S.folders.get()).?, "2"), "7z counts: {s} files, {s} folders", .{ r.get(S.files.get()).?, r.get(S.folders.get()).? });
    try t.must(std.mem.eql(u8, r.get(S.unpacked.get()).?, nice(t, text_bytes)), "unpacked {s}, expected {s}", .{ r.get(S.unpacked.get()).?, nice(t, text_bytes) });
    try t.must(std.mem.eql(u8, r.get(S.@"packed".get()).?, nice(t, size(t, seven))), "packed {s}", .{r.get(S.@"packed".get()).?});
    try t.must(std.mem.eql(u8, r.get(S.encrypted.get()).?, S.no.get()) and r.get(S.volumesCount.get()) == null, "plain 7z: encryption/volumes rows", .{});

    const zip = try Make(t, home, "plain.zip", .Zip, .{});
    r = try rows(t, zip, null);
    try t.must(std.mem.eql(u8, r.get(label(S.method)) orelse "", "Deflate") and r.get(label(S.dictionary)) == null, "zip method/dictionary: {s}", .{r.get(label(S.method)) orelse "-"});

    const parts = try Make(t, home, "vol.7z", .SevenZip, .{ .level = .None, .volume_size = 100 << 10 });
    const n = (try namesLike(t, home, "vol.7z.")).len;
    r = try rows(t, try engine.part(t.ar, parts, 1), null);
    try t.must(n >= 3 and std.mem.eql(u8, r.get(S.volumesCount.get()) orelse "", try t.ar.print("{d}", .{n})), "volume count row: {d} parts, row {s}", .{ n, r.get(S.volumesCount.get()) orelse "-" });

    const locked = try Make(t, home, "locked.7z", .SevenZip, .{ .password = "hunter2", .encrypt_headers = true });
    r = try rows(t, locked, "hunter2");
    try t.must(std.mem.eql(u8, r.get(S.encrypted.get()).?, S.encryptedDataAndNames.get()), "7z with encrypted names", .{});
    const aes = try Make(t, home, "aes.zip", .Zip, .{ .password = "hunter2" });
    r = try rows(t, aes, "hunter2");
    try t.must(std.mem.eql(u8, r.get(S.encrypted.get()).?, S.encryptedData.get()), "zip with encrypted data only", .{});
    const tgz = try Make(t, home, "t.tar.gz", .TarGz, .{});
    r = try rows(t, tgz, null);
    try t.must(std.mem.eql(u8, r.get(S.@"packed".get()).?, nice(t, size(t, tgz))), "tar.gz packed size is the inner tar's", .{});
    try t.must(engine.dictionaryOf("PPMD:o6:mem24") == 1 << 24 and engine.dictionaryOf("LZMA:1536m") == 1536 << 20 and
        engine.dictionaryOf("BCJ2 LZMA2:20 LZMA:20:lc0:lp2") == 1 << 20 and engine.dictionaryOf("Deflate") == null, "DictionaryOf", .{});
    t.say("OK info (7z, zip, volumes, encryption, tar.gz, dictionary)", .{});
}

fn reportCheck(t: *T) !void {
    const home = try t.p("report");
    // Names Windows itself would never allow, the way a zip from elsewhere can carry them.
    const zip = try join(t.ar, &.{ home, "odd.zip" });
    var bbb: [5000]u8 = @splat('b');
    try writeZip(t, zip, &.{ .{ "R&D.txt", "rd" }, .{ "x<script>alert(1)</script>.txt", "xss" }, .{ "звіт.txt", "uk" }, .{ "sub/b.txt", &bbb } });
    const a = try open(t, zip, null);
    defer a.close();
    var inf: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try engine.describe(t.ar, t.io, a)) |r| try inf.put(t.ar, r.label, r.value);

    const html = try engine.report(t.ar, t.io, a, true);
    try t.must(std.mem.find(u8, html, "R&amp;D.txt") != null and std.mem.find(u8, html, "x&lt;script&gt;alert(1)&lt;/script&gt;.txt") != null, "names are not escaped in HTML", .{});
    try t.must(std.mem.find(u8, html, "<script>") == null, "a raw <script> got into the HTML report", .{});
    try t.must(std.mem.find(u8, html, "звіт.txt") != null and std.mem.find(u8, html, "<meta charset=\"utf-8\">") != null, "Cyrillic name or charset missing from HTML", .{});

    const txt_path = try join(t.ar, &.{ home, "odd.txt" });
    try engine.writeReport(t.gpa, t.io, a, txt_path, false);
    const bytes = try readFile(t, txt_path);
    try t.must(std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF") and bytes.len > 3, "the text report has no UTF-8 BOM", .{});
    const txt = bytes[3..];
    try t.must(std.mem.find(u8, txt, "звіт.txt") != null and std.mem.find(u8, txt, "sub/b.txt") != null and std.mem.find(u8, txt, "R&D.txt") != null, "the text report lacks a file", .{});
    for ([_][]const u8{ S.files.get(), S.unpacked.get(), S.@"packed".get() }) |l| {
        const want = try t.ar.print("{s}: {s}", .{ l, inf.get(l).? });
        try t.must(std.mem.find(u8, txt, want) != null, "text report total '{s}' differs from Info ({s})", .{ l, inf.get(l).? });
    }
    var found = false;
    for ([_][]const u8{ "5,000", "5 000", "5\u{00A0}000", "5\u{202F}000", "5.000", "5000" }) |s| found = found or std.mem.find(u8, txt, s) != null;
    try t.must(found, "b.txt's size is not in the report", .{});
    const html_path = try join(t.ar, &.{ home, "odd.html" });
    try engine.writeReport(t.gpa, t.io, a, html_path, true);
    try t.must((try readFile(t, html_path))[0] == '<', "the HTML report starts with a BOM", .{});
    t.say("OK report (HTML escaping, BOM text, totals = Info)", .{});
}

fn convertCheck(t: *T) !void {
    const home = try t.p("conv");
    const H = struct {
        fn make(x: *T, h: []const u8, name: []const u8, k: ArchiveKind, o: CompressOptions) ![]const u8 {
            const path = try join(x.ar, &.{ h, name });
            try compress(x, &.{x.text}, path, k, o);
            return path;
        }
        fn conv(x: *T, src: []const u8, dst: []const u8, k: ArchiveKind, keep: bool, del: bool, pw: ?[]const u8, p: engine.Progress) !bool {
            return engine.convert(x.gpa, x.io, src, pw, dst, k, .Normal, keep, del, p, &x.diag);
        }
        fn sameAs(x: *T, h: []const u8, archive: []const u8, pw: ?[]const u8) !void {
            const a = try open(x, archive, pw);
            defer a.close();
            const dest = try join(x.ar, &.{ h, try std.mem.concat(x.ar, u8, &.{ "check-", fspath.basename(archive) }) });
            try unpack(x, a, dest, .Overwrite);
            try same(x, x.text, try join(x.ar, &.{ dest, "text" }));
        }
        fn noLeftovers(x: *T, h: []const u8, what: []const u8) !void {
            try x.must((try namesLike(x, h, ".makepack-")).len == 0, "{s} left a hidden .makepack-* file", .{what});
        }
    };
    const In = struct {
        fn f(x: *T, h: []const u8, n: []const u8) []const u8 {
            return join(x.ar, &.{ h, n }) catch "";
        }
    }.f;

    // zip -> 7z, and a nested tar.gz -> 7z: same files, original kept, its download mark carried over.
    const zip = try H.make(t, home, "a.zip", .Zip, .{});
    try writeZone(t, zip, "[ZoneTransfer]\r\nZoneId=3\r\n");
    try t.must(try H.conv(t, zip, In(t, home, "a.7z"), .SevenZip, false, false, null, .none), "zip -> 7z was not kept", .{});
    try H.sameAs(t, home, In(t, home, "a.7z"), null);
    try t.must(fileExists(zip), "the original went without delete-originals", .{});
    try t.must(engine.zoneOf(t.ar, t.io, In(t, home, "a.7z")) != null, "the converted copy lost the original's download mark", .{});
    const tgz = try H.make(t, home, "b.tar.gz", .TarGz, .{});
    try t.must(try H.conv(t, tgz, In(t, home, "b.7z"), .SevenZip, false, false, null, .none), "tar.gz -> 7z was not kept", .{});
    try H.sameAs(t, home, In(t, home, "b.7z"), null);

    // Not smaller: the old one stays, no new file.
    const tight = try H.make(t, home, "tight.7z", .SevenZip, .{ .level = .Ultra });
    try t.must(!try H.conv(t, tight, In(t, home, "tight.tar"), .Tar, true, false, null, .none), "a bigger tar replaced a 7z", .{});
    try t.must(!fileExists(In(t, home, "tight.tar")), "the bigger new archive was left", .{});
    try H.noLeftovers(t, home, "keep-if-not-smaller");

    // A new archive that fails its test: removed, original untouched.
    hook_io = t.io;
    engine.before_test_hook = damage;
    const r = H.conv(t, zip, In(t, home, "bad.7z"), .SevenZip, false, false, null, .none);
    engine.before_test_hook = null;
    try t.must(is(r, error.ConvertMismatch) and !fileExists(In(t, home, "bad.7z")) and fileExists(zip), "a damaged conversion was kept or hurt the original", .{});
    try H.noLeftovers(t, home, "a failed conversion");

    // Delete originals: to the Recycle Bin (and back, for the user's bin). Same path: replaced in place.
    const gone = try H.make(t, home, "gone.zip", .Zip, .{});
    try t.must(try H.conv(t, gone, In(t, home, "gone.7z"), .SevenZip, false, true, null, .none) and !fileExists(gone), "delete-originals kept it", .{});
    _ = try fromRecycleBin(t);
    const in_place = try H.make(t, home, "inplace.zip", .Zip, .{ .level = .None });
    const stored = size(t, in_place);
    try t.must(try H.conv(t, in_place, in_place, .Zip, false, true, null, .none), "zip -> zip in place was not kept", .{});
    try t.must(size(t, in_place) < stored, "the in-place zip was not recompressed", .{});
    try H.sameAs(t, home, in_place, null);

    // Encrypted: the password goes on; into a format without one it is refused.
    const secret = try H.make(t, home, "secret.7z", .SevenZip, .{ .password = "hunter2", .encrypt_headers = true });
    const refused = H.conv(t, secret, In(t, home, "secret.tar"), .Tar, false, false, "hunter2", .none);
    try t.must(is(refused, error.ConvertWouldDecrypt) and !fileExists(In(t, home, "secret.tar")), "an encrypted archive was converted into plain tar", .{});
    try t.must(try H.conv(t, secret, In(t, home, "secret.zip"), .Zip, false, false, "hunter2", .none), "encrypted 7z -> zip was not kept", .{});
    {
        const z = try open(t, In(t, home, "secret.zip"), null);
        defer z.close();
        for (z.items()) |it| if (!it.is_dir) try t.must(it.encrypted, "the converted zip is not encrypted", .{});
    }
    try H.sameAs(t, home, In(t, home, "secret.zip"), "hunter2");

    // Cancel: nothing half-made.
    var c: Canceler = .{ .past = 50 };
    _ = H.conv(t, zip, In(t, home, "cancel.7z"), .SevenZip, false, false, null, c.progress()) catch {};
    try t.must(!fileExists(In(t, home, "cancel.7z")) and fileExists(zip), "cancel left a new archive or hurt the original", .{});
    try H.noLeftovers(t, home, "cancel");
    t.say("OK convert (zip, tar.gz, not smaller, damaged, delete, in place, encrypted, cancel)", .{});
}

fn profiles(t: *T) !void {
    const path = try t.p("cfg-profiles\\settings.json");
    const fresh_profile: settings.Profile = .{ .Name = "Fresh" };
    try t.must(fresh_profile.Method == .Default, "a new profile's method is not Default (the zero value is Copy = no compression)", .{});
    const list = [_]settings.Profile{
        .{ .Name = "Backup", .IsDefault = true, .Format = .Zip, .Level = .High, .Method = .Lzma, .Dictionary = 4 << 20, .Threads = 2, .Volumes = "700 MB (CD)", .TestAfter = true, .DeleteSources = true, .Separate = true, .ZipCrypto = true },
        .{ .Name = "Setup", .Format = .SevenZip, .Sfx = true, .Solid = "off", .Filter = "BCJ2" },
    };
    const cfg: settings.Settings = .{ .Profiles = &list };
    try settings.saveOrFail(&cfg, t.gpa, t.io, path);
    var back = settings.load(t.gpa, t.io, path);
    defer back.deinit();
    const b = back.v.findProfile("backup") orelse return t.must(false, "no profile 'backup'", .{}); // names match case-insensitively
    try t.must(back.v.Profiles.len == 2 and b.IsDefault and b.Format == .Zip and b.Method == .Lzma and std.mem.eql(u8, b.Volumes, "700 MB (CD)") and
        b.Separate and b.ZipCrypto and b.DeleteSources, "a profile did not survive the save/load round trip", .{});
    try t.must(std.ascii.findIgnoreCase(try readFile(t, path), "Password") == null, "a profile carries a password field", .{});
    const o = b.toOptions();
    try t.must(o.password == null and !o.zip_crypto and !o.encrypt_headers, "a profile run without the dialog asked for encryption", .{});
    try t.must(o.volume_size == 700 << 20 and o.dictionary == 4 << 20 and o.test_after and o.delete_sources, "toOptions lost an option", .{});
    const setup_p = back.v.findProfile("Setup").?;
    try t.must(std.mem.eql(u8, setup_p.ext(), ".exe") and setup_p.toOptions().sfx and std.mem.eql(u8, setup_p.toOptions().solid orelse "", "off"), "the SFX profile", .{});

    // The same default name the dialog proposes: one input -> its name, several -> their folder's.
    const dir = try t.p("names");
    try Io.Dir.cwd().createDirPath(t.io, try join(t.ar, &.{ dir, "photos" }));
    try writeFile(t, try join(t.ar, &.{ dir, "a.txt" }), "a");
    const photos = try join(t.ar, &.{ dir, "photos" });
    const a_txt = try join(t.ar, &.{ dir, "a.txt" });
    var name = try engine.defaultArchivePath(t.ar, t.io, &.{photos}, ".zip", null);
    try t.must(std.mem.eql(u8, name, try join(t.ar, &.{ dir, "photos.zip" })), "single folder name: {s}", .{name});
    name = try engine.defaultArchivePath(t.ar, t.io, &.{a_txt}, ".7z", null);
    try t.must(std.mem.eql(u8, name, try join(t.ar, &.{ dir, "a.7z" })), "single file name: {s}", .{name});
    name = try engine.defaultArchivePath(t.ar, t.io, &.{ a_txt, photos }, ".7z", t.root);
    try t.must(std.mem.eql(u8, name, try t.p("names.7z")), "several inputs into a folder: {s}", .{name});

    // A profile with options its format cannot take (hand-edited JSON) fails before anything is written.
    const broken: settings.Profile = .{ .Name = "Broken", .Format = .Zip, .Solid = "on" };
    const target = try t.p("broken.zip");
    const r = engine.compress(t.gpa, t.io, &.{a_txt}, target, broken.Format, broken.toOptions(), .none, null);
    try t.must(is(r, error.InvalidOption) and !fileExists(target), "an impossible profile was not refused up front", .{});
    t.say("OK profiles (round trip, no password, options, names, refused)", .{});
}

// ---- cli (MP-C's cli.run end to end) ---------------------------------------------------------------------

const Cli = struct {
    t: *T,
    aw: Io.Writer.Allocating,

    fn run(c: *Cli, args: []const []const u8) i32 {
        c.aw.clearRetainingCapacity();
        const env: cli.Env = .{ .gpa = c.t.gpa, .io = c.t.io, .out = &c.aw.writer, .err = &c.aw.writer, .ask_password = noAsk, .motw = .Never, .engine_dir = c.t.engine_dir };
        return if (cli.run(env, args)) |code| code else -1;
    }

    fn expect(c: *Cli, want: i32, args: []const []const u8) !void {
        const got = c.run(args);
        const line = std.mem.join(c.t.ar, " ", args) catch "";
        try c.t.must(got == want, "'{s}' exited {d}, expected {d}: {s}", .{ line, got, want, std.mem.trim(u8, c.aw.written(), " \r\n") });
    }

    fn noAsk(_: Allocator, _: []const u8, _: ?[]const u8) ?[]u8 {
        return null;
    }
};

fn setPasswordVar(value: ?[]const u8) void {
    const n = kit.win.L(cli.password_variable);
    if (value) |v| {
        const wv = kit.win.toW(std.heap.smp_allocator, v) catch return;
        defer std.heap.smp_allocator.free(wv);
        _ = w.SetEnvironmentVariableW(n, wv.ptr);
    } else _ = w.SetEnvironmentVariableW(n, null);
}

fn cliCheck(t: *T) !void {
    const home = try t.p("cli");
    try Io.Dir.cwd().createDirPath(t.io, home);
    var c: Cli = .{ .t = t, .aw = .init(t.ar) };
    const In = struct {
        fn f(x: *T, h: []const u8, n: []const u8) []const u8 {
            return join(x.ar, &.{ h, n }) catch "";
        }
    }.f;
    const old = try kit.win.getEnv(t.ar, cli.password_variable);
    defer setPasswordVar(old);
    setPasswordVar(null);

    // a -switches: headless, format from -t or the extension, volumes, no overwrite without -y.
    const zip = In(t, home, "out.zip");
    try c.expect(0, &.{ "a", "-m5", zip, t.text });
    {
        const z = try open(t, zip, null);
        defer z.close();
        try t.must(z.x.props.format == .Zip, "a -m5 out.zip did not write a zip", .{});
    }
    try c.expect(2, &.{ "a", "-m1", zip, t.text }); // exists, no -y
    try c.expect(0, &.{ "a", "-y", "-t7z", zip, t.text }); // -t beats the extension
    {
        const z = try open(t, zip, null);
        defer z.close();
        try t.must(z.x.props.format == .SevenZip, "-t7z ignored", .{});
    }
    const bare = In(t, home, "bare");
    try c.expect(0, &.{ "a", "-ttar.gz", bare, try join(t.ar, &.{ t.text, "*.txt" }) }); // a mask, and the extension added
    {
        const z = try open(t, try std.mem.concat(t.ar, u8, &.{ bare, ".tar.gz" }), null);
        defer z.close();
        var files: usize = 0;
        for (z.items()) |it| files += @intFromBool(!it.is_dir);
        try t.must(files == 2, "the mask did not pick exactly a.txt and b.txt", .{});
    }
    const vol = In(t, home, "vol.7z");
    try c.expect(0, &.{ "a", "-v20k", vol, t.text });
    try t.must(fileExists(try engine.part(t.ar, vol, 2)), "-v20k made no second part", .{});
    try c.expect(7, &.{ "a", "-q", zip, t.text });
    try c.expect(7, &.{ "a", "-psecret", zip, t.text }); // never a password in the arguments
    try c.expect(7, &.{ "a", "-hpsecret", zip, t.text });
    try c.expect(7, &.{ "a", "-v0", zip, t.text });
    try c.expect(10, &.{ "a", "-y", zip, In(t, home, "nothing*.xyz") });

    // Password from the environment only; t/l/x refuse to guess without one.
    const secret = In(t, home, "secret.7z");
    setPasswordVar("hunter2");
    try c.expect(0, &.{ "a", "-hp", secret, t.text });
    try c.expect(0, &.{ "t", secret });
    try c.expect(0, &.{ "x", "-y", secret, "-o", In(t, home, "x-secret") });
    try same(t, t.text, In(t, home, "x-secret\\text"));
    setPasswordVar("WRONG");
    try c.expect(11, &.{ "t", secret });
    try c.expect(7, &.{ "a", "-y", "-p", "-ttar", In(t, home, "p.tar"), t.text }); // tar takes no password
    try c.expect(0, &.{ "a", "-y", In(t, home, "open.7z"), t.text }); // no -p: the variable is not used
    try t.must(opens(t, In(t, home, "open.7z")) and c.run(&.{ "t", In(t, home, "open.7z") }) == 0, "a without -p encrypted", .{});
    setPasswordVar(null);
    try c.expect(11, &.{ "t", secret });
    try c.expect(11, &.{ "l", secret });

    // t: intact 0, damaged 3, not an archive 2, missing 10; l lists to stdout.
    try c.expect(0, &.{ "t", zip });
    try c.expect(0, &.{ "l", try std.mem.concat(t.ar, u8, &.{ vol, ".001" }) });
    try t.must(std.mem.find(u8, c.aw.written(), "sub/c.txt") != null or std.mem.find(u8, c.aw.written(), "sub\\c.txt") != null, "l did not list sub/c.txt", .{});
    const bytes = try readFile(t, zip);
    // The packed data only: with the header gone too, an unopenable 7z reads as one with encrypted names (11).
    var i: usize = 64;
    while (i < bytes.len / 2) : (i += 7) bytes[i] ^= 0x5A;
    const bad = In(t, home, "bad.7z");
    try writeFile(t, bad, bytes);
    try c.expect(3, &.{ "t", bad });
    const plain = In(t, home, "plain.txt");
    var aw: Io.Writer.Allocating = .init(t.ar);
    for (0..1000) |_| try aw.writer.writeAll("not an archive\r\n");
    try writeFile(t, plain, aw.written());
    try c.expect(2, &.{ "t", plain });
    try c.expect(10, &.{ "t", In(t, home, "missing.7z") });
    try c.expect(7, &.{ "t", "-psecret", zip });

    // x -y: an unsafe entry is skipped and the rest extracted -> a warning (1).
    const evil = In(t, home, "evil.zip");
    try writeZip(t, evil, &.{ .{ "ok.txt", "ok.txt" }, .{ "../escaped.txt", "../escaped.txt" } });
    try c.expect(1, &.{ "x", "-y", evil, "-o", In(t, home, "x-evil") });
    try t.must(fileExists(In(t, home, "x-evil\\ok.txt")) and !fileExists(In(t, home, "escaped.txt")), "x -y on the unsafe zip", .{});

    // Not ours: the GUI keeps these.
    try t.must(c.run(&.{ "a", "--quick", zip }) == -1 and c.run(&.{ "a", zip }) == -1 and c.run(&.{ "x", zip, "--here" }) == -1, "a GUI command was taken", .{});
    try t.must(engine.exitCodeOf(error.Canceled) == 255 and engine.exitCodeOf(error.NoInputs) == 10 and engine.exitCodeOf(error.NoSpaceLeft) == 2, "ExitCodeOf", .{});
    // cli.run's engine.deinit took the temp dirs along; the engine itself stays loaded (init is repeatable).
    try engine.init(t.gpa, t.io, t.engine_dir);
    t.say("OK cli (a switches, volumes, masks, refused password, env password, t/l/x codes 0 1 2 3 7 10 11)", .{});
}

fn packedCheck(t: *T) !void {
    // C# reached into SevenZipSharp by reflection here; the binding reads kpidPackSize directly. Still: every kind,
    // encrypted too, many times over, and the file must not stay locked afterwards.
    for ([_]struct { ArchiveKind, ?[]const u8 }{ .{ .SevenZip, null }, .{ .Zip, null }, .{ .TarGz, null }, .{ .SevenZip, "pw" } }) |c| {
        const k, const pass = c;
        const arc = try t.p(try t.ar.print("packed-{t}-{s}{s}", .{ k, pass orelse "", types.kind(k).ext }));
        try pack(t, &.{t.src}, arc, k, pass, pass != null);
        for (0..20) |_| {
            const a = try open(t, arc, pass);
            defer a.close();
            var sum: u64 = 0;
            for (a.items()) |it| sum += it.packed_size orelse 0;
            try t.must(sum > 0 and sum <= size(t, arc), "{t}: packed total {d} of {d}", .{ k, sum, size(t, arc) });
        }
        const moved = try std.mem.concat(t.ar, u8, &.{ arc, ".moved" });
        try Io.Dir.renameAbsolute(arc, moved, t.io); // fails if a handle was left open
        try Io.Dir.renameAbsolute(moved, arc, t.io);
    }
    t.say("OK packed (7z, zip, tar.gz, encrypted 7z; repeated; no lock left)", .{});
}

// ---- platform (MP-C): registry verbs in a throwaway hive, single instance on a private name ------------------

/// --register / --addmenu / heal / --unregister under HKCU\Software\MakePackTest-<random> (deleted afterwards):
/// never the real Software\Classes, Software\MakePack or RegisteredApplications.
fn registryCheck(t: *T) !void {
    var rnd: [8]u8 = undefined;
    t.io.random(&rnd);
    const key = try t.ar.print("Software\\MakePackTest-{x}", .{&rnd});
    defer kit.win.deleteKeyTree(.hkcu, key, .default) catch {};
    const prefix = try std.mem.concat(t.ar, u8, &.{ key, "\\" });
    const h: assoc.Hive = .{ .prefix = prefix };
    var aw: Io.Writer.Allocating = .init(t.ar);
    const env: cli.Env = .{ .gpa = t.gpa, .io = t.io, .out = &aw.writer, .err = &aw.writer, .ask_password = Cli.noAsk, .hive = h };
    const in_menu = [_]settings.Profile{.{ .Name = "Backup", .InMenu = true, .Format = .Zip }};
    const exists = struct {
        fn f(p: []const u8, sub: []const u8) bool {
            var buf: [512]u8 = undefined;
            const k = kit.win.openKey(.hkcu, std.mem.print(&buf, "{s}{s}", .{ p, sub }) catch return false, .{}) catch return false;
            k.close();
            return true;
        }
    }.f;

    try t.must(cli.registryVerb(env, &.{ "--register", "defaults" }, &in_menu) == 0, "--register: {s}", .{aw.written()});
    try t.must(assoc.isOurs(h, "7z") and !assoc.isOurs(h, "iso"), "--register defaults did not claim exactly the free default types", .{});
    try assoc.heal(h); // a healthy registration: only read
    try t.must(assoc.isOurs(h, "7z"), "heal broke a healthy registration", .{});
    try t.must(cli.registryVerb(env, &.{ "--addmenu", "on" }, &in_menu) == 0, "--addmenu on: {s}", .{aw.written()});
    try t.must(assoc.menu(h).add and exists(prefix, "Software\\MakePack\\MenuProfiles\\01"), "--addmenu on: no file menu or profile item", .{});
    try t.must(cli.registryVerb(env, &.{"--unregister"}, &in_menu) == 0, "--unregister: {s}", .{aw.written()});
    try t.must(!assoc.isOurs(h, "7z") and !exists(prefix, "Software\\Classes\\" ++ assoc.prog_id), "--unregister left the registration", .{});
    t.say("OK registry (register, heal, addmenu, unregister; test hive)", .{});
}

/// The mutex + pipe protocol on a private name (never "MakePack-<session>": that is the user's running MakePack).
fn singleCheck(t: *T) !void {
    var rnd: [8]u8 = undefined;
    t.io.random(&rnd);
    const name = try t.ar.print("MakePack-selftest-{x}", .{&rnd});
    var first = try single.Instance.acquire(name);
    defer first.release();
    var second: ?single.Instance = null;
    const th = try std.Thread.spawn(.{}, struct { // a mutex is re-entrant on its own thread: ask from another one
        fn f(n: []const u8, out: *?single.Instance) void {
            var i = single.Instance.acquire(n) catch return;
            out.* = i;
            i.release();
        }
    }.f, .{ name, &second });
    th.join();
    try t.must(first.server and second != null and !second.?.server, "the second instance did not become a client", .{});

    const Got = struct {
        ar: Allocator,
        args: ?[]const []const u8 = null,
        fn f(ctx: ?*anyopaque, args: []const []const u8) void {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            const copy = g.ar.alloc([]const u8, args.len) catch return;
            for (args, copy) |s, *d| d.* = g.ar.dupe(u8, s) catch return;
            g.args = copy;
        }
    };
    var got: Got = .{ .ar = t.ar };
    const pipe = try kit.win.toW(t.ar, try std.mem.concat(t.ar, u8, &.{ "\\\\.\\pipe\\", name }));
    const server = try std.Thread.spawn(.{}, struct {
        fn f(g: Allocator, p: [:0]const u16, hd: single.Handler) void {
            single.serveOne(g, p, hd) catch {};
        }
    }.f, .{ t.gpa, pipe, single.Handler{ .ctx = &got, .f = Got.f } });
    const sent = [_][]const u8{ "x", "C:\\Тека з пробілом\\архів.7z", "--here" };
    const ok = single.send(t.gpa, name, &sent);
    if (ok) server.join() else server.detach(); // nobody connected: the thread stays blocked, the process exits anyway
    try t.must(ok and got.args != null and got.args.?.len == sent.len, "the arguments did not arrive over the pipe", .{});
    for (sent, got.args.?) |want, g| try t.must(std.mem.eql(u8, want, g), "'{s}' arrived as '{s}'", .{ want, g });
    t.say("OK single (mutex owner/client, pipe round trip; private name)", .{});
}

// ---- gui (MP-G1): the main window's model, never shown -------------------------------------------------------

/// Program.SelfTest "gui": disk and archive listings, "..", history, nested archives, flat view, folder sizes,
/// the status line and the address; then the Ukrainian plurals of the status line.
fn guiCheck(t: *T) !void {
    const gui = try t.p("gui");
    try Io.Dir.cwd().createDirPath(t.io, try join(t.ar, &.{ gui, "alpha" }));
    try Io.Dir.cwd().createDirPath(t.io, try join(t.ar, &.{ gui, "beta", "inner" }));
    try pack(t, &.{t.src}, try join(t.ar, &.{ gui, "pack.zip" }), .Zip, null, false);
    const inner = try t.p("inner.zip");
    try pack(t, &.{try join(t.ar, &.{ t.src, "a.txt" })}, inner, .Zip, null, false);
    try pack(t, &.{inner}, try join(t.ar, &.{ gui, "outer.7z" }), .SevenZip, null, false);

    var m = try mw.Model.init(t.gpa, t.io, gui);
    defer m.deinit();
    try m.go(.{ .path = gui }, null, false);
    try t.must(eqlS(try guiNames(t, &m), "..|alpha|beta|outer.7z|pack.zip"), "disk list: {s}", .{try guiNames(t, &m)});
    try guiOpen(t, &m, "pack.zip");
    try t.must(eqlS(try guiNames(t, &m), "..|src"), "archive root: {s}", .{try guiNames(t, &m)});
    var total: u64 = 0;
    {
        var dir = try Io.Dir.cwd().openDir(t.io, t.src, .{ .iterate = true });
        defer dir.close(t.io);
        var walker = try dir.walk(t.gpa);
        defer walker.deinit();
        while (try walker.next(t.io)) |e| if (e.kind == .file) {
            total += size(t, try join(t.ar, &.{ t.src, e.path }));
        };
    }
    var g: [40]u8 = undefined;
    try t.must(eqlS(try guiCell(t, &m, "src", .size), S.group(&g, total)), "folder size {s}, files {d}", .{ try guiCell(t, &m, "src", .size), total });
    try t.must((try guiCell(t, &m, "src", .@"packed")).len > 0, "the Packed column is empty", .{});
    var sb: [512]u8 = undefined;
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const status = m.statusText(&sb);
    try t.must(std.mem.find(u8, status, S.foldersN(&b1, 1)) != null and std.mem.find(u8, status, S.bytes(&b2, total)) != null, "status: {s}", .{status});
    var ab: [1024]u8 = undefined;
    const address = m.addressText(&ab);
    try t.must(std.mem.find(u8, address, "pack.zip") != null and std.mem.find(u8, address, "ZIP") != null, "address: {s}", .{address});
    var tb: [1024]u8 = undefined;
    try t.must(std.mem.find(u8, m.titleText(&tb), "pack.zip") != null, "title: {s}", .{m.titleText(&tb)});
    try guiOpen(t, &m, "src");
    const in_src = try guiNames(t, &m);
    try t.must(std.mem.find(u8, in_src, "|sub") != null and std.mem.find(u8, in_src, "|a.txt") != null and std.mem.find(u8, in_src, "|void") != null, "inside src: {s}", .{in_src});
    try guiDone(t, &m, m.up());
    try t.must(eqlS(try guiNames(t, &m), "..|src") and eqlS(guiChosen(&m), "src"), "up inside the archive: {s} chosen {s}", .{ try guiNames(t, &m), guiChosen(&m) });
    try guiDone(t, &m, m.up());
    try t.must(std.mem.find(u8, try guiNames(t, &m), "|alpha") != null and eqlS(guiChosen(&m), "pack.zip"), "up out of the archive: {s}", .{guiChosen(&m)});
    try guiDone(t, &m, m.goBack());
    try t.must(eqlS(try guiNames(t, &m), "..|src"), "back into the archive: {s}", .{try guiNames(t, &m)});
    try guiDone(t, &m, m.goForward());
    try t.must(std.mem.find(u8, try guiNames(t, &m), "|alpha") != null, "forward to the folder: {s}", .{try guiNames(t, &m)});
    try guiOpen(t, &m, "outer.7z");
    try guiOpen(t, &m, "inner.zip");
    try t.must(eqlS(try guiNames(t, &m), "..|a.txt"), "nested archive: {s}", .{try guiNames(t, &m)});
    try guiDone(t, &m, m.up());
    try t.must(eqlS(guiChosen(&m), "inner.zip") and std.mem.find(u8, m.addressText(&ab), "outer.7z") != null, "up from a nested archive: {s}", .{m.addressText(&ab)});
    try guiDone(t, &m, m.up());
    try t.must(eqlS(guiChosen(&m), "outer.7z") and std.mem.find(u8, try guiNames(t, &m), "|alpha") != null, "up from the outer archive: {s}", .{guiChosen(&m)});
    try guiOpen(t, &m, "pack.zip");
    m.flat = true;
    try m.fill(false, null);
    const flat = try guiNames(t, &m);
    try t.must(std.mem.find(u8, flat, "|b.bin") != null and std.mem.find(u8, flat, "|тест ïé.txt") != null and std.mem.find(u8, flat, "|src") == null, "flat view: {s}", .{flat});
    m.flat = false;
    try m.fill(false, null);
    try t.must(eqlS(try guiNames(t, &m), "..|src"), "flat view off: {s}", .{try guiNames(t, &m)});
    if (S.uk) for ([_]struct { u64, []const u8 }{ .{ 1, "файл" }, .{ 2, "файли" }, .{ 5, "файлів" }, .{ 11, "файлів" }, .{ 12, "файлів" }, .{ 21, "файл" }, .{ 22, "файли" }, .{ 111, "файлів" } }) |c| {
        const n, const word = c;
        const s = S.filesN(&b1, n);
        try t.must(std.mem.endsWith(u8, s, word) and s[s.len - word.len - 1] == ' ', "{d} -> {s}", .{ n, s });
    };
    t.say("OK gui (disk, archive, folder sizes, packed, status, up/back/forward, nested, flat, plurals)", .{});
}

fn eqlS(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn guiNames(t: *T, m: *const mw.Model) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (m.rows.items) |r| try list.append(t.ar, r.name);
    return std.mem.join(t.ar, "|", list.items);
}

/// MainForm.Chosen: the one selected row ("" when none or several).
fn guiChosen(m: *const mw.Model) []const u8 {
    var found: []const u8 = "";
    var n: usize = 0;
    for (m.rows.items) |r| if (r.selected) {
        found = r.name;
        n += 1;
    };
    return if (n == 1) found else "";
}

fn guiCell(t: *T, m: *const mw.Model, name: []const u8, c: mw.Col) ![]const u8 {
    for (m.rows.items) |r| if (eqlS(r.name, name)) return t.ar.dupe(u8, m.cell(try t.ar.alloc(u8, 64), r, c));
    return "";
}

/// MainForm.Open(name): Enter on that row; an archived file goes through a temp dir first (ToTemp, no window).
fn guiOpen(t: *T, m: *mw.Model, name: []const u8) !void {
    for (m.rows.items, 0..) |r, i| if (eqlS(r.name, name)) {
        switch (m.activate(i, false) catch |e| return guiDone(t, m, e)) {
            .extract => |x| {
                const rel = try t.ar.dupe(u8, x.rel);
                const dir = try m.toTempSync(x.index);
                defer t.gpa.free(dir);
                _ = m.afterTemp(dir, rel, x.as_archive) catch |e| return guiDone(t, m, e);
            },
            else => {},
        }
        return;
    };
    try t.must(false, "no row {s}", .{name});
}

/// The window's error.NeedOpen (Dialogs.openArchive on a job, then goWith), here without one: open, then goWith.
fn guiDone(t: *T, m: *mw.Model, r: anyerror!void) !void {
    r catch |e| {
        if (e != error.NeedOpen) return e;
        var want = m.want.?;
        m.want = null;
        defer want.saved.deinit();
        const a = try engine.open(t.gpa, t.io, want.saved.loc.path, want.saved.loc.password, .none, null);
        try m.goWith(want.saved.loc, a, want.select, want.record);
    };
}

test "contract compiles" {
    @import("testutil.zig").refAllDeep(@This(), 2);
}
