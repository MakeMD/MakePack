//! MakePack.exe entry: Program.Main's dispatch order, verbatim.
//!   --selftest -> --register/--unregister/--addmenu -> --assoc/--settings (standalone dialog, no pipe) ->
//!   headless CLI (t, l, a -sw, x -y) -> one process per session (mutex + pipe) -> GUI.
//! GUI (docs/ZIG-PORT.md "GUI"): our own arguments and every forwarded set go through the Inbox to the UI thread,
//! then Dialogs.dispatch (Program.Dispatch). Per frame: inbox -> dispatch, requests -> main.zig (.open_main) or
//! MainWindow.handle, MainWindow.draw, Dialogs.draw, MaybeExit (no main window and the dialogs idle -> quit).
const std = @import("std");
const kit = @import("kit");
const S = @import("strings.zig");
const settings = @import("settings.zig");
const selftest = @import("selftest.zig");
const engine = @import("core/engine.zig");
const assoc = @import("platform/assoc.zig");
const single = @import("platform/single.zig");
const cli = @import("platform/cli.zig");
const pw = @import("platform/platform_win.zig");
const C = @import("ui/ctx.zig");
const Dialogs = @import("ui/dialogs.zig").Dialogs;
const MainWindow = @import("ui/main_window.zig").MainWindow;

const Allocator = std.mem.Allocator;
const im = kit.im;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args: []const []const u8 = argv[1..];
    S.init();

    if (args.len > 0 and eql(args[0], "--selftest")) return selftest.run(gpa, io);

    settings.init(gpa, io); // Settings.Current
    defer settings.deinit();
    kit.i18n.apply(settings.current().lang()); // the saved language from here on: CLI, dialogs, main window
    const hive = testHive(arena);
    const env: cli.Env = .{ .gpa = gpa, .io = io, .ask_password = Dialogs.cliAskPassword, .hive = hive };

    if (args.len > 0 and (eql(args[0], "--register") or eql(args[0], "--unregister") or eql(args[0], "--addmenu")))
        return cli.registryVerb(env, args, settings.current().Profiles);

    // AssocForm.Edit(null) / SettingsForm.Edit(null): the dialog alone, before the CLI and the single instance.
    if (args.len > 0 and eql(args[0], "--assoc")) return gui(gpa, io, .assoc, hive);
    if (args.len > 0 and eql(args[0], "--settings")) return gui(gpa, io, .settings, hive);

    if (cli.run(env, args)) |code| return code; // scripts: no window, no queue

    // One process per session. MAKEPACK_INSTANCE (tests only) replaces "MakePack-<session>", so a test never
    // hands its arguments to the user's running MakePack.
    var name_buf: [32]u8 = undefined;
    const test_name = kit.win.getEnv(arena, "MAKEPACK_INSTANCE") catch null;
    const name = test_name orelse single.sessionName(&name_buf);
    var instance: ?single.Instance = single.Instance.acquire(name) catch null;
    defer if (instance) |*i| i.release();
    inbox.gpa = gpa;
    defer inbox.deinit();
    if (instance) |i| {
        if (!i.server) {
            if (single.send(gpa, name, single.absolute(arena, args) catch args)) return 0;
            // Nobody answered within 1.5 s: the server was on its way out. ponytail: run standalone.
        } else {
            single.serve(gpa, name, .{ .f = forwarded }) catch {};
            // A broken registry must never stop the app from starting. A test run (MAKEPACK_INSTANCE) never touches
            // the real HKCU registration, not even to heal it; with MAKEPACK_REGROOT it heals its own test root.
            if (hive.prefix.len > 0 or test_name == null) assoc.heal(hive) catch {};
        }
    }
    inbox.push(args); // Program.Post(args): our own arguments take the same road as forwarded ones
    return gui(gpa, io, .args, hive);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Tests only: MAKEPACK_REGROOT (e.g. `Software\MakePackTest-<random>`) is an HKCU subkey that stands in for HKCU
/// itself in every Assoc read and write - the registry verbs, the Associations dialog, Settings' menu profiles,
/// Heal: `.7z` lands in `HKCU\<root>\Software\Classes\.7z`. MAKEPACK_HIVE is the older name. Unset = the real HKCU.
fn testHive(arena: Allocator) assoc.Hive {
    const raw = (kit.win.getEnv(arena, "MAKEPACK_REGROOT") catch null) orelse
        (kit.win.getEnv(arena, "MAKEPACK_HIVE") catch null) orelse return .{};
    const root = std.mem.trim(u8, raw, " \\");
    if (root.len == 0) return .{};
    return .{ .prefix = std.mem.concat(arena, u8, &.{ root, "\\" }) catch @panic("MAKEPACK_REGROOT: out of memory") }; // never fall back to the real HKCU
}

// ---- pipe thread -> UI thread ----------------------------------------------------------------------------

/// Program.Post: argument lists waiting for Dispatch. push from any thread, take on the UI thread.
const Inbox = struct {
    gpa: Allocator = undefined,
    lock: kit.win.Lock = .{},
    lists: std.ArrayList([][]u8) = .empty,

    fn push(ib: *Inbox, args: []const []const u8) void {
        const copy = ib.gpa.alloc([]u8, args.len) catch return;
        for (args, 0..) |a, i| copy[i] = ib.gpa.dupe(u8, a) catch {
            for (copy[0..i]) |s| ib.gpa.free(s);
            return ib.gpa.free(copy);
        };
        ib.lock.lock();
        defer ib.lock.unlock();
        ib.lists.append(ib.gpa, copy) catch kit.win.freeList(ib.gpa, copy);
    }

    fn take(ib: *Inbox) std.ArrayList([][]u8) {
        ib.lock.lock();
        defer ib.lock.unlock();
        const taken = ib.lists;
        ib.lists = .empty;
        return taken;
    }

    fn deinit(ib: *Inbox) void {
        var left = ib.take();
        for (left.items) |l| kit.win.freeList(ib.gpa, l);
        left.deinit(ib.gpa);
    }
};

var inbox: Inbox = .{};

/// Another invocation's arguments (pipe thread, valid during the call): no arguments = "show me the window".
fn forwarded(_: ?*anyopaque, args: []const []const u8) void {
    inbox.push(args);
    kit.app.wakeGlobal();
}

// ---- GUI ---------------------------------------------------------------------------------------------------

/// Everything the UI thread owns (Program's statics). Fixed address for the whole run (ctx is pointed at).
const Ui = struct {
    ctx: C.Ctx,
    dialogs: Dialogs = undefined,
    /// Program._main
    mw: ?MainWindow = null,
};

const Mode = enum { args, assoc, settings };

fn gui(gpa: Allocator, io: std.Io, mode: Mode, hive: assoc.Hive) !u8 {
    const exe = try pw.exePath(gpa);
    defer gpa.free(exe);
    const exe_dir = pw.directoryName(exe) orelse ".";
    // Engine's static constructor: 7z.dll next to the exe. A failure is reported once the window is up.
    const engine_err: ?anyerror = if (engine.init(gpa, io, exe_dir)) null else |e| e;
    defer engine.deinit(io); // temp dirs (ToTemp, drag-out, nested archives)
    // What killed runs left in %TEMP%\MakePack, off the UI thread (a stale nested .tar can be big).
    if (std.Thread.spawn(.{}, engine.sweepStaleTemps, .{io})) |t| t.detach() else |_| {}

    const app = try kit.app.App.init(gpa, .{
        .title = S.app,
        .size = .{ 900, 600 },
        .palette = kit.app.palettes.carbon,
        .icon_id = 1,
    });
    defer app.deinit(); // runs after ui's deinit below: jobs are joined before the app goes

    var ui: Ui = .{ .ctx = .{ .gpa = gpa, .io = io, .app = app, .exe_dir = exe_dir, .standalone = mode != .args } };
    ui.ctx.hive = hive; // tests: MAKEPACK_REGROOT
    ui.dialogs = Dialogs.init(&ui.ctx);
    ui.ctx.dialogs = &ui.dialogs;
    defer {
        if (ui.mw) |*m| m.deinit();
        ui.ctx.updates.deinit(gpa);
        ui.dialogs.deinit();
        var left = ui.ctx.takeRequests();
        for (left.items) |r| r.deinit(gpa);
        left.deinit(gpa);
    }

    if (engine_err) |e| ui.dialogs.fail(e);
    switch (mode) {
        .args => {},
        .assoc => ui.dialogs.assoc(),
        .settings => ui.dialogs.settings(),
    }
    app.run(.{ .user = &ui, .frame = frame, .close_requested = closeRequested, .files_dropped = filesDropped });
    return ui.ctx.exit_code;
}

fn frame(app: *kit.app.App) void {
    const ui = app.userData(Ui);
    const gpa = ui.ctx.gpa;

    // 1. Program.Dispatch for every argument list that arrived (ours first, then the forwarded ones).
    var lists = inbox.take();
    for (lists.items) |l| {
        ui.dialogs.dispatch(@ptrCast(l));
        kit.win.freeList(gpa, l);
    }
    lists.deinit(gpa);

    // 2. Requests from the dialogs, before anything draws (ctx.zig).
    var reqs = ui.ctx.takeRequests();
    for (reqs.items) |r| switch (r) {
        .open_main => |p| {
            openMain(ui, p);
            r.deinit(gpa);
        },
        else => if (ui.mw) |*m| m.handle(r) else r.deinit(gpa),
    };
    reqs.deinit(gpa);

    ui.ctx.updates.poll(&ui.ctx);

    // 3. + 4.
    if (ui.mw) |*m| if (!m.draw()) closeMain(ui);
    ui.dialogs.draw();

    // 5. Program.MaybeExit: nothing on screen and nothing queued - the session is over.
    if (ui.mw == null and ui.dialogs.idle()) app.quit();
}

/// Program.OpenMain: one window; a path arriving while it exists opens in it.
fn openMain(ui: *Ui, path: ?[]const u8) void {
    if (ui.mw) |*m| {
        if (path) |p| m.open(p);
    } else {
        ui.mw = @as(MainWindow, undefined);
        ui.mw.?.init(&ui.ctx, path);
        ui.ctx.has_main_window = true;
        ui.ctx.updates.daily(&ui.ctx);
    }
    ui.ctx.raise();
}

fn closeMain(ui: *Ui) void {
    if (ui.mw) |*m| m.deinit();
    ui.mw = null;
    ui.ctx.has_main_window = false;
}

/// The OS window's X / Alt+F4. With a main window: it closes (C# FormClosed), and the process ends only when the
/// dialogs are idle - else the OS window lives on for them (the queue's progress). Never under a modal dialog.
fn closeRequested(app: *kit.app.App) bool {
    const ui = app.userData(Ui);
    if (ui.dialogs.modal()) return false;
    if (ui.mw == null) return ui.dialogs.closeRequested();
    closeMain(ui);
    return ui.dialogs.idle();
}

fn filesDropped(app: *kit.app.App, paths: []const []const u8, pos: im.ImVec2) void {
    const ui = app.userData(Ui);
    if (ui.dialogs.filesDropped(paths)) return;
    if (ui.mw) |*m| m.filesDropped(paths, pos);
}
