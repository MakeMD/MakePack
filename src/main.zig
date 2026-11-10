//! MakePack.exe entry: Program.Main's dispatch order, verbatim.
//!   --selftest -> --register/--unregister/--addmenu -> --assoc/--settings -> headless CLI (t, l, a -sw, x -y)
//!   -> one process per session (mutex + pipe) -> GUI.
//! GUI is a placeholder in this phase (window + empty main menu); Program.Dispatch (x queue, a dialog,
//! a --quick/--profile, convert, open archive) arrives with the GUI phase.
const std = @import("std");
const kit = @import("kit");
const S = @import("strings.zig");
const settings = @import("settings.zig");
const selftest = @import("selftest.zig");
const assoc = @import("platform/assoc.zig");
const single = @import("platform/single.zig");
const cli = @import("platform/cli.zig");

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
    const env: cli.Env = .{ .gpa = gpa, .io = io, .ask_password = noPassword };

    if (args.len > 0 and (eql(args[0], "--register") or eql(args[0], "--unregister") or eql(args[0], "--addmenu")))
        return cli.registryVerb(env, args, settings.current().Profiles);

    // GUI phase: AssocForm.Edit(null) / SettingsForm.Edit(null), the dialogs standalone.
    if (args.len > 0 and (eql(args[0], "--assoc") or eql(args[0], "--settings"))) return 0;

    if (cli.run(env, args)) |code| return code; // scripts: no window, no queue

    // One process per session. MAKEPACK_INSTANCE (tests only) replaces "MakePack-<session>", so a test never
    // hands its arguments to the user's running MakePack.
    var name_buf: [32]u8 = undefined;
    const test_name = kit.win.getEnv(arena, "MAKEPACK_INSTANCE") catch null;
    const name = test_name orelse single.sessionName(&name_buf);
    var instance: ?single.Instance = single.Instance.acquire(name) catch null;
    defer if (instance) |*i| i.release();
    if (instance) |i| {
        if (!i.server) {
            if (single.send(gpa, name, single.absolute(arena, args) catch args)) return 0;
            // Nobody answered within 1.5 s: the server was on its way out. ponytail: run standalone.
        } else {
            single.serve(gpa, name, .{ .f = forwarded }) catch {};
            // A broken registry must never stop the app from starting. A test run (MAKEPACK_INSTANCE) never touches
            // the real HKCU registration, not even to heal it.
            if (test_name == null) assoc.heal(.{}) catch {};
        }
    }
    return gui(gpa);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Until the GUI phase brings PasswordForm: -p behaves as if the user cancelled the prompt.
fn noPassword(_: std.mem.Allocator, _: []const u8, _: ?[]const u8) ?[]u8 {
    return null;
}

/// Another invocation's arguments (pipe thread). GUI phase: post them to Program.Dispatch on the UI thread.
fn forwarded(_: ?*anyopaque, _: []const []const u8) void {
    kit.app.wakeGlobal();
}

// ---- GUI placeholder -------------------------------------------------------------------------------------

fn gui(gpa: std.mem.Allocator) !u8 {
    const app = try kit.app.App.init(gpa, .{
        .title = S.app,
        .size = .{ 900, 600 },
        .palette = kit.app.palettes.pack,
        .icon_id = 1,
    });
    defer app.deinit();
    app.run(.{ .frame = frame });
    return 0;
}

const im = kit.im;

/// The main menu (MAIN_MENU): captions without the WinForms '&', ids stable across languages.
const menus = [_]struct { S.Str, []const u8 }{
    .{ S.mFile, "mfile" },
    .{ S.mCommands, "mcommands" },
    .{ S.mTools, "mtools" },
    .{ S.mFavorites, "mfavorites" },
    .{ S.mOptions, "moptions" },
    .{ S.mHelp, "mhelp" },
};

fn frame(_: *kit.app.App) void {
    const vp = im.ImGui_GetMainViewport();
    im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
    im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
    _ = im.ImGui_Begin("MakePack##main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove |
        im.ImGuiWindowFlags_NoSavedSettings | im.ImGuiWindowFlags_NoBringToFrontOnFocus | im.ImGuiWindowFlags_MenuBar);
    defer im.ImGui_End();
    if (im.ImGui_BeginMenuBar()) {
        for (menus) |m| {
            var plain: [64]u8 = undefined;
            var label: [96]u8 = undefined;
            const z = std.mem.printSentinel(&label, "{s}###{s}", .{ S.plain(&plain, m[0].get()), m[1] }, 0) catch continue;
            if (im.ImGui_BeginMenu(z.ptr)) im.ImGui_EndMenu();
        }
        im.ImGui_EndMenuBar();
    }
}
