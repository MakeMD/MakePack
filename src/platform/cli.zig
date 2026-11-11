//! MP-C: the scriptable commands (Cli.cs), Program.RegistryVerb and Program.UseConsole.
//! No main window, no mutex: output to stdout, errors to stderr (engine.friendly), exit codes
//! (engine.exitCodeOf). A password never travels in the arguments: -p asks for it in a window, and
//! MAKEPACK_PASSWORD serves unattended runs.
//!   t [-p] archive                        test
//!   l [-p] archive                        list (the text report)
//!   a -switch... archive files|masks...   create: -t7z|zip|tar|tar.gz|..., -m0..5, -v100m, -p, -hp, -y
//!   x -y [-p] archive [-o dir | --sub]    extract quietly, overwriting
//! tools/bugtest.ps1 is the black-box test of this contract (exit codes and messages).
//! The argument checks and decisions (parse*, planAdd, passwordFor) are separate from the engine calls, so
//! they are testable on their own.
const std = @import("std");
const kit = @import("kit");
const assoc = @import("assoc.zig");
const settings = @import("../settings.zig");
const engine = @import("../core/engine.zig");
const types = @import("../core/types.zig");
const S = @import("../strings.zig");
const pw = @import("platform_win.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = engine.Diag;
const eql = std.mem.eql;

pub const password_variable = "MAKEPACK_PASSWORD";

pub const Env = struct {
    gpa: Allocator,
    io: Io,
    /// null = the process's stdout / stderr (after useConsole). Tests pass their own writers.
    out: ?*Io.Writer = null,
    err: ?*Io.Writer = null,
    /// PasswordForm.Ask(owner, title, label): a window asking for a password; null = the user cancelled.
    /// Result allocated with the allocator passed in. Only -p / -hp ever call it. The GUI phase provides the
    /// window (core and platform never show UI); until then main passes one that cancels.
    ask_password: *const fn (gpa: Allocator, title: []const u8, label: ?[]const u8) ?[]u8,
    /// Registry root for registryVerb (tests: a MakePackTest key).
    hive: assoc.Hive = .{},
    /// Mark-of-the-Web policy for x; null = settings.current().Motw (C# read Settings.Current).
    motw: ?types.MotwPolicy = null,
    /// The folder holding 7z.dll; null = the exe's folder (tests: paths.seven_zip_dll's folder).
    engine_dir: ?[]const u8 = null,
};

/// C#'s Engine static constructor loaded 7z.dll on first use; run() does the same: engine.init right before the
/// first engine call (argument and file checks stay usable without it), engine.deinit when run() returns.
/// Requires engine.init/deinit to be repeatable within one process (tests call run() many times).
const Engine = struct {
    up: bool = false,

    fn start(e: *Engine, env: Env, a: Allocator) !void {
        if (e.up) return;
        const dir = env.engine_dir orelse pw.directoryName(try pw.exePath(a)) orelse return error.FileNotFound;
        try engine.init(env.gpa, env.io, dir);
        e.up = true;
    }
};

/// Ctrl+C / Ctrl+Break in the console (Console.CancelKeyPress): the running operation ends with 255.
var cancel_flag: std.atomic.Value(bool) = .init(false);

fn onCtrl(ctrl: w.DWORD) callconv(.c) w.WINBOOL {
    if (ctrl > 1) return 0; // CTRL_C_EVENT = 0, CTRL_BREAK_EVENT = 1; close/logoff: the default
    cancel_flag.store(true, .release);
    return 1;
}

fn progress() engine.Progress {
    return .{ .cancel = &cancel_flag };
}

/// Cli.Run's first half: `t`/`l` always, `a` when args[1] is a single-dash switch (a <paths> and a --quick
/// are Explorer's verbs), `x` with -y. Everything else goes to the GUI.
pub fn headless(args: []const []const u8) bool {
    if (args.len < 2) return false;
    const v = args[0];
    if (eql(u8, v, "t") or eql(u8, v, "l")) return true;
    if (eql(u8, v, "a")) return args[1].len > 0 and args[1][0] == '-' and !std.mem.startsWith(u8, args[1], "--");
    if (eql(u8, v, "x")) return has(args, "-y");
    return false;
}

/// Cli.Run: null = not a scripted command (the GUI takes the arguments); otherwise the exit code.
pub fn run(env: Env, args: []const []const u8) ?u8 {
    if (!headless(args)) return null;
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var fo: Io.File.Writer = undefined;
    var fe: Io.File.Writer = undefined;
    if (env.out == null or env.err == null) {
        useConsole();
        _ = w.SetConsoleCtrlHandler(onCtrl, 1);
    }
    const out = env.out orelse blk: {
        fo = Io.File.stdout().writer(env.io, &out_buf);
        break :blk &fo.interface;
    };
    const err = env.err orelse blk: {
        fe = Io.File.stderr().writer(env.io, &err_buf);
        break :blk &fe.interface;
    };
    defer {
        out.flush() catch {};
        err.flush() catch {};
    }
    var arena: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena.deinit();
    var diag: Diag = .{};
    var eng: Engine = .{};
    defer if (eng.up) engine.deinit(env.io);
    return exec(env, &eng, arena.allocator(), out, args, &diag) catch |e| {
        out.flush() catch {};
        err.print("{s}\r\n", .{engine.friendly(e, &diag)}) catch {};
        return engine.exitCodeOf(e);
    };
}

fn exec(env: Env, eng: *Engine, a: Allocator, out: *Io.Writer, args: []const []const u8, diag: *Diag) !u8 {
    const v = args[0];
    const rest = args[1..];
    if (eql(u8, v, "t")) {
        const p = try parseOne(a, rest, diag);
        const arc = try openArchive(env, eng, a, p.archive, p.ask, diag);
        defer arc.close();
        try needBodyPassword(arc);
        if (!try engine.testArchive(env.gpa, env.io, arc, progress(), diag)) {
            diag.len = 0;
            return error.Damaged;
        }
        try out.print("{s}\r\n", .{S.testOk.get()});
    } else if (eql(u8, v, "l")) {
        const p = try parseOne(a, rest, diag);
        const arc = try openArchive(env, eng, a, p.archive, p.ask, diag);
        defer arc.close();
        const text = try engine.report(env.gpa, env.io, arc, false);
        defer env.gpa.free(text);
        try out.writeAll(text);
    } else if (eql(u8, v, "a")) {
        const plan = try planAdd(env, a, rest, diag);
        try eng.start(env, a);
        // A set is replaced part by part by compress itself; one file is moved aside, not deleted (see moveAside).
        const backup = if (plan.replace) try moveAside(env.io, a, plan.archive) else null;
        engine.compress(env.gpa, env.io, plan.inputs, plan.archive, plan.kind, plan.options, progress(), diag) catch |e| {
            if (backup) |b| putBack(env.io, b, plan.archive);
            return e;
        };
        if (backup) |b| Io.Dir.cwd().deleteFile(env.io, b) catch {};
    } else {
        const p = try parseExtract(a, rest, diag);
        const arc = try openArchive(env, eng, a, p.archive, p.ask, diag);
        defer arc.close();
        try needBodyPassword(arc);
        const dest = try extractDest(a, p);
        const motw = env.motw orelse settings.current().Motw;
        try engine.extract(env.gpa, env.io, arc, dest, null, .Overwrite, progress(), .always_overwrite, motw, .{}, diag);
    }
    return 0;
}

// ---- argument parsing --------------------------------------------------------------------------------

/// Cli.Bad: a switch that looks like a password in the arguments gets the "use -p or MAKEPACK_PASSWORD" answer.
fn bad(diag: *Diag, arg: []const u8) error{ PasswordInArgs, BadSwitch } {
    if (std.ascii.startsWithIgnoreCase(arg, "-p") or std.ascii.startsWithIgnoreCase(arg, "-hp")) return error.PasswordInArgs;
    Diag.set(diag, S.cliBadSwitchFmt.get(), .{arg});
    return error.BadSwitch;
}

/// Cli.One: exactly one archive.
fn one(rest: []const []const u8, diag: *Diag) ![]const u8 {
    if (rest.len == 1) return rest[0];
    return bad(diag, if (rest.len == 0) "<archive>" else rest[1]);
}

fn has(args: []const []const u8, s: []const u8) bool {
    for (args) |x| if (eql(u8, x, s)) return true;
    return false;
}

fn isSwitch(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

pub const OneArchive = struct { archive: []const u8, ask: bool };

/// t / l: Split(args, "-p") + One.
pub fn parseOne(a: Allocator, args: []const []const u8, diag: *Diag) !OneArchive {
    var rest: std.ArrayList([]const u8) = .empty;
    var ask = false;
    for (args) |x| {
        if (!isSwitch(x)) {
            try rest.append(a, x);
        } else if (eql(u8, x, "-p")) {
            ask = true;
        } else return bad(diag, x);
    }
    return .{ .archive = try one(rest.items, diag), .ask = ask };
}

pub const ExtractArgs = struct { archive: []const u8, ask: bool, dest: ?[]const u8, sub: bool };

/// x -y [-p] archive [-o dir | --sub | --here]
pub fn parseExtract(a: Allocator, args: []const []const u8, diag: *Diag) !ExtractArgs {
    var dest: ?[]const u8 = null;
    var sub = false;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (eql(u8, x, "-y") or eql(u8, x, "-p") or eql(u8, x, "--here")) continue;
        if (eql(u8, x, "--sub")) {
            sub = true;
        } else if (eql(u8, x, "-o") and i + 1 < args.len) {
            i += 1;
            dest = args[i];
        } else if (isSwitch(x)) {
            return bad(diag, x);
        } else try rest.append(a, x);
    }
    return .{ .archive = try one(rest.items, diag), .ask = has(args, "-p"), .dest = dest, .sub = sub };
}

/// Cli.Extract's destination: -o wins; else --sub = the archive's folder + Engine.BaseName (x.tar.gz -> x);
/// else the archive's own folder (a relative archive name is taken from the current directory).
pub fn extractDest(a: Allocator, p: ExtractArgs) ![]const u8 {
    if (p.dest) |d| return d;
    const dir = pw.directoryName(try pw.fullPath(a, p.archive)) orelse return error.FileNotFound;
    return if (p.sub) std.fs.path.join(a, &.{ dir, engine.baseName(p.archive) }) else dir;
}

/// `a -y` over an existing archive. C# deleted it before Compress, so any failure (the archive inside its own
/// sources, an unreadable input, a mask that matched the archive itself) lost it. Here it is renamed to
/// "<archive>.makepack~" (a numbered name when that is taken - never overwrite an older backup), deleted
/// after a successful compress and put back by putBack after a failed one.
pub fn moveAside(io: Io, a: Allocator, path: []const u8) ![]const u8 {
    var name = try std.mem.concat(a, u8, &.{ path, ".makepack~" });
    var n: u32 = 2;
    while (pw.fileExists(name) or pw.dirExists(name)) : (n += 1) name = try a.print("{s}.makepack~{d}", .{ path, n });
    try Io.Dir.cwd().renamePreserve(path, Io.Dir.cwd(), name, io);
    return name;
}

/// Undo moveAside: the backup replaces whatever the failed compress left at `path`. ponytail: if even that
/// fails the backup simply stays next to it under its .makepack~ name - nothing is deleted.
pub fn putBack(io: Io, backup: []const u8, path: []const u8) void {
    Io.Dir.cwd().rename(backup, Io.Dir.cwd(), path, io) catch {};
}

/// Everything `a` needs, decided before anything is written.
pub const AddPlan = struct {
    archive: []const u8,
    kind: types.ArchiveKind,
    inputs: []const []const u8,
    options: types.CompressOptions,
    /// The archive exists, -y was given and it is one file: delete it first.
    replace: bool,
};

/// Cli.Add up to the Compress call: switches (before the archive name only), the archive's full path, kind and
/// extension, the inputs (masks expanded), the password, and the existing-archive check.
pub fn planAdd(env: Env, a: Allocator, args: []const []const u8, diag: *Diag) !AddPlan {
    var kind: ?types.ArchiveKind = null;
    var level: types.CompressionLevel = .Normal;
    var volume: i64 = 0;
    var ask = false;
    var headers = false;
    var overwrite = false;
    var rest: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (!isSwitch(arg) or rest.items.len > 0) { // switches go before the archive name
            try rest.append(a, arg);
            continue;
        }
        const s = try std.ascii.allocLowerString(a, arg);
        if (std.mem.startsWith(u8, s, "-t")) {
            kind = kindNamed(s[2..]) orelse return bad(diag, arg);
        } else if (s.len == 3 and s[1] == 'm' and s[2] >= '0' and s[2] <= '5') {
            level = @fromBackingInt(s[2] - '0');
        } else if (std.mem.startsWith(u8, s, "-v")) {
            volume = types.parseSize(s[2..]) orelse 0;
            if (volume <= 0) return bad(diag, arg);
        } else if (eql(u8, s, "-p")) {
            ask = true;
        } else if (eql(u8, s, "-hp")) {
            ask = true;
            headers = true;
        } else if (eql(u8, s, "-y")) {
            overwrite = true;
        } else return bad(diag, arg);
    }
    if (rest.items.len < 2) return bad(diag, if (rest.items.len == 0) "<archive>" else "<files>");

    var archive: []const u8 = pw.fullPath(a, rest.items[0]) catch return bad(diag, rest.items[0]);
    const k = kind orelse kindOfName(archive);
    const info = types.kind(k);
    if (pw.extension(archive).len == 0) archive = try std.mem.concat(a, u8, &.{ archive, info.ext });

    var inputs: std.ArrayList([]const u8) = .empty;
    for (rest.items[1..]) |x| try expand(env.io, a, x, &inputs, diag);
    // Only with -p/-hp: a MAKEPACK_PASSWORD left in the environment must not encrypt archives nobody asked to.
    const password = if (ask) try getPassword(env, a, pw.fileName(archive), true, true) else null;
    if (password != null and !info.password) {
        Diag.set(diag, S.cliNoPasswordFmt.get(), .{info.name});
        return error.NoPasswordForFormat;
    }
    if (headers and k != .SevenZip) return bad(diag, "-hp"); // ponytail (from C#): reported like a password in the arguments

    const taken = pw.fileExists(if (volume > 0) try engine.part(a, archive, 1) else archive);
    if (taken and !overwrite) {
        Diag.set(diag, S.cliExistsFmt.get(), .{archive});
        return error.AlreadyExists;
    }
    return .{
        .archive = archive,
        .kind = k,
        .inputs = inputs.items,
        .options = .{ .level = level, .password = password, .encrypt_headers = headers, .volume_size = volume },
        .replace = taken and volume == 0,
    };
}

/// Cli.KindNamed: "7z", "tar.gz" (also tgz/tbz2/txz)...
fn kindNamed(name: []const u8) ?types.ArchiveKind {
    const n = if (eql(u8, name, "tgz")) "tar.gz" else if (eql(u8, name, "tbz2")) "tar.bz2" else if (eql(u8, name, "txz")) "tar.xz" else name;
    for (types.kinds) |ki| if (eql(u8, ki.name, n)) return ki.kind;
    return null;
}

/// The longest known extension the name ends with ("x.tar.gz" = TarGz, not GZip); none = SevenZip.
fn kindOfName(archive: []const u8) types.ArchiveKind {
    var best: ?types.KindInfo = null;
    for (types.kinds) |ki| {
        if (std.ascii.endsWithIgnoreCase(archive, ki.ext) and (best == null or ki.ext.len > best.?.ext.len)) best = ki;
    }
    return if (best) |b| b.kind else .SevenZip;
}

/// Cli.Expand: a path, or a mask in its last part (cmd hands "*.txt" over as is).
fn expand(io: Io, a: Allocator, arg: []const u8, list: *std.ArrayList([]const u8), diag: *Diag) !void {
    const full = pw.fullPath(a, arg) catch return bad(diag, arg);
    if (pw.fileExists(full) or pw.dirExists(full)) return list.append(a, full);
    const mask = pw.fileName(full);
    const before = list.items.len;
    if (pw.directoryName(full)) |dir| {
        if (std.mem.findAny(u8, mask, "*?") != null and pw.dirExists(dir)) {
            var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |e| {
                // A name toW cannot take (a lone surrogate in WTF-8) is skipped, not a failure of the whole `a`.
                if (matches(a, e.name, mask) catch false) try list.append(a, try std.fs.path.join(a, &.{ dir, e.name }));
            }
        }
    }
    if (list.items.len == before) {
        Diag.set(diag, S.cliNoMatchFmt.get(), .{arg});
        return error.FileNotFound;
    }
}

/// Directory.GetFileSystemEntries' mask: '*' and '?', case-insensitive (OrdinalIgnoreCase), "*.*" = all.
/// ponytail: plain glob; the DOS corner cases ("*." = no extension, '?' matching nothing before a dot) are not
/// reproduced - nobody types those into a script.
fn matches(a: Allocator, name: []const u8, mask: []const u8) !bool {
    const n = try kit.win.toW(a, name);
    const m = try kit.win.toW(a, if (eql(u8, mask, "*.*")) "*" else mask);
    return types.globIgnoreCase(n, m);
}

// ---- passwords and opening -----------------------------------------------------------------------------

fn envPassword(a: Allocator) ?[]const u8 {
    const v = (kit.win.getEnv(a, password_variable) catch null) orelse return null;
    return if (v.len > 0) v else null;
}

/// Cli.Password: MAKEPACK_PASSWORD first (unattended runs); otherwise -p asks in a window.
fn getPassword(env: Env, a: Allocator, title: []const u8, ask: bool, confirm: bool) ![]const u8 {
    if (envPassword(a)) |p| return p;
    if (!ask) return error.PasswordNeeded;
    const label: ?[]const u8 = if (confirm) try std.mem.concat(a, u8, &.{ S.password.get(), ":" }) else null;
    const first = env.ask_password(a, title, label) orelse return error.Canceled;
    if (confirm) {
        const again = env.ask_password(a, title, S.confirm.get());
        if (again == null or !eql(u8, again.?, first)) return error.PasswordsDiffer;
    }
    return first;
}

/// Cli.Open's decision after Engine.Probe: refuse what is not an archive, ask for a password when the file
/// list is behind one, and take one given up front (-p or MAKEPACK_PASSWORD) for the bodies too.
pub fn passwordFor(env: Env, a: Allocator, path: []const u8, probe: engine.ProbeResult, ask: bool) !?[]const u8 {
    switch (probe) {
        .not_archive => return error.NotAnArchive,
        .damaged => return error.Damaged,
        .encrypted_headers => return try getPassword(env, a, pw.fileName(path), ask, false),
        .archive => {},
    }
    if (ask or envPassword(a) != null) return try getPassword(env, a, pw.fileName(path), ask, false);
    return null;
}

/// Cli.Open: the same checks as PasswordForm.OpenArchive, as errors instead of message boxes.
fn openArchive(env: Env, eng: *Engine, a: Allocator, path: []const u8, ask: bool, diag: *Diag) !*engine.Archive {
    if (!pw.fileExists(path)) {
        Diag.set(diag, S.fileNotFoundFmt.get(), .{path});
        return error.FileNotFound;
    }
    try eng.start(env, a);
    const password = try passwordFor(env, a, path, engine.probe(env.io, path), ask);
    return engine.open(env.gpa, env.io, path, password, .none, diag) catch |e| {
        if (e != error.Canceled and engine.canEncryptHeaders(env.io, path)) {
            diag.len = 0;
            return if (password == null) error.PasswordNeeded else error.WrongPassword;
        }
        return e;
    };
}

/// Bodies encrypted but the file list not: no password, no extraction.
fn needBodyPassword(arc: *const engine.Archive) !void {
    if (arc.password != null) return;
    for (arc.items()) |it| if (it.encrypted) return error.PasswordNeeded;
}

// ---- --register [defaults|ext,ext] / --unregister [ext,ext] / --addmenu on|off ----------------------------

/// Program.RegistryVerb: silent, no UI, exit 0/1 (the message on stdout on failure). The installer calls
/// these; SHChangeNotify once at the end (not for a test hive: Explorer never sees it).
pub fn registryVerb(env: Env, args: []const []const u8, profiles: []const settings.Profile) u8 {
    var arena: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena.deinit();
    registryVerbInner(env, arena.allocator(), args, profiles) catch |e| {
        var buf: [1024]u8 = undefined;
        var fo: Io.File.Writer = undefined;
        const out = env.out orelse blk: {
            useConsole();
            fo = Io.File.stdout().writer(env.io, &buf);
            break :blk &fo.interface;
        };
        out.print("{s}\r\n", .{engine.friendly(e, null)}) catch {};
        out.flush() catch {};
        return 1;
    };
    if (env.hive.prefix.len == 0) assoc.notify();
    return 0;
}

fn registryVerbInner(env: Env, a: Allocator, args: []const []const u8, profiles: []const settings.Profile) !void {
    const h = env.hive;
    const arg = if (args.len > 1) args[1] else "";
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, arg, ',');
    while (it.next()) |raw| {
        const e = std.mem.trimStart(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), ".");
        if (e.len == 0) continue; // ponytail guard: "." would have registered Software\Classes\. itself
        try list.append(a, try std.ascii.allocLowerString(a, e));
    }
    if (eql(u8, args[0], "--register")) {
        if (list.items.len == 0 or eql(u8, arg, "defaults")) {
            for (assoc.all) |ext| _ = try assoc.register(h, ext, false);
        } else for (list.items) |ext| _ = try assoc.register(h, ext, true);
    } else if (eql(u8, args[0], "--unregister")) {
        if (list.items.len == 0) try assoc.unregisterAll(h) else for (list.items) |ext| try assoc.unregister(h, ext);
    } else if (eql(u8, args[0], "--addmenu")) {
        try assoc.setAddMenu(h, eql(u8, arg, "on"), profiles);
    }
}

// ---- the console ---------------------------------------------------------------------------------------

var console_done = false;

/// Program.UseConsole: gives the GUI-subsystem process a usable stdout/stderr - AttachConsole(ATTACH_PARENT)
/// only when it has no standard handles (attaching would steal output from a caller that redirected us to a
/// pipe or file), then UTF-8 output. Once.
pub fn useConsole() void {
    if (console_done) return;
    console_done = true;
    const h = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) _ = w.AttachConsole(w.ATTACH_PARENT_PROCESS);
    _ = w.SetConsoleOutputCP(65001); // Console.OutputEncoding = UTF8 (fails harmlessly without a console)
}

test "contract compiles" {
    @import("../testutil.zig").refAllDeep(@This(), 2);
}

test "glob: *, ?, case, *.*" {
    const glob = types.globIgnoreCase;
    const L = kit.win.L;
    try std.testing.expect(glob(L("a.TXT"), L("*.txt")));
    try std.testing.expect(!glob(L("a.txt~"), L("*.txt")));
    try std.testing.expect(glob(L("ab.c.txt"), L("a?.*.txt")));
    try std.testing.expect(glob(L("Їжак.7z"), L("їж*")));
    try std.testing.expect(!glob(L("abc"), L("a?")));
    try std.testing.expect(glob(L(""), L("*")));
}
