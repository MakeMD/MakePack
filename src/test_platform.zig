//! test-platform (MP-C owns this file): Assoc (under testutil.regTestKey only), single instance (own mutex/pipe
//! name), CLI (Env with captured writers; argument checks and decisions without the engine, end-to-end runs
//! through the real engine).
const std = @import("std");
const kit = @import("kit");
const testutil = @import("testutil.zig");
const assoc = @import("platform/assoc.zig");
const single = @import("platform/single.zig");
const cli = @import("platform/cli.zig");
const pw = @import("platform/platform_win.zig");
const settings = @import("settings.zig");
const engine = @import("core/engine.zig");
const types = @import("core/types.zig");
const S = @import("strings.zig");

const testing = std.testing;
const reg = kit.win;
const Allocator = std.mem.Allocator;

test {
    _ = @import("platform/assoc.zig");
    _ = @import("platform/single.zig");
    _ = @import("platform/cli.zig");
    _ = @import("platform/platform_win.zig");
    _ = @import("platform/platform_dispatch.zig");
}

// ---- helpers -------------------------------------------------------------------------------------------

const classes = "Software\\Classes\\";
const file_exts = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\";

/// HKCU\Software\MakePackTest-<random>: the only registry a test touches; removed by deinit.
const TestHive = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    prefix: []const u8,

    fn init() !TestHive {
        var t: TestHive = .{ .arena = .init(testing.allocator), .key = "", .prefix = "" };
        const a = t.arena.allocator();
        t.key = try testutil.regTestKey(a, testing.io);
        t.prefix = try std.mem.concat(a, u8, &.{ t.key, "\\" });
        return t;
    }

    fn deinit(t: *TestHive) void {
        reg.deleteKeyTree(.hkcu, t.key, .default) catch {};
        t.arena.deinit();
    }

    fn hive(t: *const TestHive) assoc.Hive {
        return .{ .prefix = t.prefix };
    }

    fn full(t: *TestHive, path: []const u8) []const u8 {
        return std.mem.concat(t.arena.allocator(), u8, &.{ t.prefix, path }) catch unreachable;
    }

    /// The string value, null = key or value missing (or not a string).
    fn str(t: *TestHive, path: []const u8, name: ?[]const u8) ?[]const u8 {
        const k = reg.openKey(.hkcu, t.full(path), .{}) catch return null;
        defer k.close();
        return k.readString(t.arena.allocator(), name) catch null;
    }

    fn dword(t: *TestHive, path: []const u8, name: []const u8) ?u32 {
        const k = reg.openKey(.hkcu, t.full(path), .{}) catch return null;
        defer k.close();
        return k.readDword(name) catch null;
    }

    fn binary(t: *TestHive, path: []const u8, name: []const u8) ?[]const u8 {
        const k = reg.openKey(.hkcu, t.full(path), .{}) catch return null;
        defer k.close();
        const v = k.readRaw(t.arena.allocator(), name) catch return null;
        return if (v.kind == kit.w.REG_BINARY) v.data else null;
    }

    fn exists(t: *TestHive, path: []const u8) bool {
        const k = reg.openKey(.hkcu, t.full(path), .{}) catch return false;
        k.close();
        return true;
    }

    fn set(t: *TestHive, path: []const u8, name: ?[]const u8, value: []const u8) !void {
        const k = try reg.createKey(.hkcu, t.full(path), .default);
        defer k.close();
        try k.writeString(name, value);
    }

    fn setDword(t: *TestHive, path: []const u8, name: []const u8, value: u32) !void {
        const k = try reg.createKey(.hkcu, t.full(path), .default);
        defer k.close();
        try k.writeDword(name, value);
    }

    fn print(t: *TestHive, comptime f: []const u8, args: anytype) []const u8 {
        return t.arena.allocator().print(f, args) catch unreachable;
    }
};

fn expectStr(want: []const u8, got: ?[]const u8) !void {
    if (got == null) {
        std.debug.print("expected \"{s}\", the value is missing\n", .{want});
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings(want, got.?);
}

fn exePath(t: *TestHive) []const u8 {
    return pw.exePath(t.arena.allocator()) catch unreachable;
}

/// What a verb key must hold: caption, Icon and the command.
fn expectVerb(t: *TestHive, key: []const u8, caption: []const u8, args: []const u8) !void {
    const exe = exePath(t);
    try expectStr(caption, t.str(key, null));
    try expectStr(t.print("\"{s}\",0", .{exe}), t.str(key, "Icon"));
    try expectStr(t.print("\"{s}\"{s}", .{ exe, args }), t.str(t.print("{s}\\command", .{key}), null));
}

fn neverAsk(_: Allocator, _: []const u8, _: ?[]const u8) ?[]u8 {
    return null;
}

var ask_count: usize = 0;

fn askSame(gpa: Allocator, _: []const u8, _: ?[]const u8) ?[]u8 {
    ask_count += 1;
    return gpa.dupe(u8, "pw") catch null;
}

fn askDiffer(gpa: Allocator, _: []const u8, _: ?[]const u8) ?[]u8 {
    ask_count += 1;
    return gpa.dupe(u8, if (ask_count == 1) "one" else "two") catch null;
}

fn envFor(h: assoc.Hive, out: *std.Io.Writer, err: *std.Io.Writer, ask: *const fn (Allocator, []const u8, ?[]const u8) ?[]u8) cli.Env {
    const dll_dir = std.fs.path.dirname(@import("paths").seven_zip_dll).?;
    return .{ .gpa = testing.allocator, .io = testing.io, .out = out, .err = err, .ask_password = ask, .hive = h, .motw = .Never, .engine_dir = dll_dir };
}

/// 7z.dll must load (a missing or wrong path fails the test, never skips it).
fn needEngine() !void {
    try engine.init(testing.allocator, testing.io, std.fs.path.dirname(@import("paths").seven_zip_dll).?);
    engine.deinit(testing.io); // cli.run inits and deinits per run, like the real process
}

/// MAKEPACK_PASSWORD for one test; restore() puts the previous value back.
const PasswordVar = struct {
    old: ?[]u8,

    fn set(value: ?[]const u8) !PasswordVar {
        const old = try reg.getEnv(testing.allocator, cli.password_variable);
        try testutil.setEnv(cli.password_variable, value);
        return .{ .old = old };
    }

    fn restore(p: *PasswordVar) void {
        testutil.setEnv(cli.password_variable, p.old) catch {};
        if (p.old) |o| testing.allocator.free(o);
    }
};

// ---- assoc ---------------------------------------------------------------------------------------------

test "assoc: MenuItems and QuickKind (Software\\MakePack MenuItems / QuickFormat / QuickExt)" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();

    try testing.expectEqual(assoc.MenuItems.all_items, assoc.menu(h)); // missing = all on
    try assoc.setMenu(h, .{ .open = true, .add = true });
    try testing.expectEqual(@as(?u32, 9), t.dword("Software\\MakePack", "MenuItems"));
    try testing.expectEqual(assoc.MenuItems{ .open = true, .add = true }, assoc.menu(h));
    try t.setDword("Software\\MakePack", "MenuItems", 0x100 | 2); // unknown bits are masked off
    try testing.expectEqual(assoc.MenuItems{ .extract_here = true }, assoc.menu(h));
    try t.set("Software\\MakePack", "MenuItems", "8"); // not a DWORD = all
    try testing.expectEqual(assoc.MenuItems.all_items, assoc.menu(h));

    try testing.expectEqual(types.ArchiveKind.SevenZip, assoc.quickKind(h));
    try assoc.setQuickKind(h, .Zip);
    try expectStr("Zip", t.str("Software\\MakePack", "QuickFormat"));
    try expectStr(".zip", t.str("Software\\MakePack", "QuickExt"));
    try testing.expectEqual(types.ArchiveKind.Zip, assoc.quickKind(h));
    try assoc.setQuickKind(h, .TarGz);
    try expectStr(".tar.gz", t.str("Software\\MakePack", "QuickExt"));
    try testing.expectEqual(types.ArchiveKind.TarGz, assoc.quickKind(h));
    try assoc.setQuickKind(h, .GZip); // a single-file kind cannot take a selection
    try testing.expectEqual(types.ArchiveKind.SevenZip, assoc.quickKind(h));
    try t.set("Software\\MakePack", "QuickFormat", "zip"); // Enum.TryParse is case-sensitive
    try testing.expectEqual(types.ArchiveKind.SevenZip, assoc.quickKind(h));
    try t.set("Software\\MakePack", "QuickFormat", " TarXz ");
    try testing.expectEqual(types.ArchiveKind.TarXz, assoc.quickKind(h));
    try t.set("Software\\MakePack", "QuickFormat", "3"); // Enum.TryParse takes the number too
    try testing.expectEqual(types.ArchiveKind.TarGz, assoc.quickKind(h));
    try t.set("Software\\MakePack", "QuickFormat", "99");
    try testing.expectEqual(types.ArchiveKind.SevenZip, assoc.quickKind(h));
}

test "assoc: the real HKCR branch (Hive{}) - read-only: owner and isOurs agree with HKEY_CLASSES_ROOT" {
    // Reads only: no write, heal or register may ever run against Hive{} in a test.
    const want = blk: {
        const k = reg.openKey(.hkcr, ".txt", .{}) catch break :blk null;
        defer k.close();
        break :blk k.readString(testing.allocator, null) catch null;
    };
    defer if (want) |s| testing.allocator.free(s);
    const o = try assoc.owner(testing.allocator, .{}, "txt");
    defer if (o.prog_id) |p| testing.allocator.free(p);
    if (want) |s| try expectStr(s, o.prog_id) else try testing.expect(o.prog_id == null);
    try testing.expectEqual(want != null and std.mem.eql(u8, want.?, assoc.prog_id), assoc.isOurs(.{}, "txt"));

    var nb: [64]u8 = undefined;
    const none = testName(&nb); // an extension nobody registered
    const n = try assoc.owner(testing.allocator, .{}, none);
    try testing.expect(n.prog_id == null and !n.dead and !n.user_choice and !n.choice_dead);
    try testing.expect(!assoc.isOurs(.{}, none));
}

test "assoc: --register defaults writes the ProgID, Capabilities, verbs and claims only the free default types" {
    var t = try TestHive.init();
    defer t.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const env = envFor(t.hive(), &aw.writer, &aw.writer, neverAsk);
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--register", "defaults" }, &.{}));
    try testing.expectEqualStrings("", aw.written());

    const exe = exePath(&t);
    const p = classes ++ assoc.prog_id;
    try expectStr(S.tr().progIdDesc, t.str(p, null));
    try expectStr(t.print("\"{s}\",0", .{exe}), t.str(p ++ "\\DefaultIcon", null));
    try expectStr(t.print("\"{s}\" \"%1\"", .{exe}), t.str(p ++ "\\shell\\open\\command", null));
    try expectVerb(&t, p ++ "\\shell\\MakePack.ExtractHere", S.tr().verbExtractHere, " x \"%1\" --here");
    try expectVerb(&t, p ++ "\\shell\\MakePack.ExtractTo", S.tr().verbExtractTo, " x \"%1\" --sub");
    try expectStr("MakePack", t.str("Software\\MakePack\\Capabilities", "ApplicationName"));
    try expectStr(S.tr().progIdDesc, t.str("Software\\MakePack\\Capabilities", "ApplicationDescription"));
    try expectStr("Software\\MakePack\\Capabilities", t.str("Software\\RegisteredApplications", "MakePack"));

    for (assoc.all) |ext| {
        try expectStr(assoc.prog_id, t.str("Software\\MakePack\\Capabilities\\FileAssociations", t.print(".{s}", .{ext})));
        try expectStr("", t.str(t.print(classes ++ ".{s}\\OpenWithProgids", .{ext}), assoc.prog_id));
        const shell = t.print(classes ++ "SystemFileAssociations\\.{s}\\shell\\MakePack.", .{ext});
        try expectVerb(&t, t.print("{s}Open", .{shell}), S.tr().verbOpenWith, " \"%1\"");
        try expectVerb(&t, t.print("{s}ExtractHere", .{shell}), S.tr().verbExtractHere, " x \"%1\" --here");
        try expectVerb(&t, t.print("{s}ExtractTo", .{shell}), S.tr().verbExtractTo, " x \"%1\" --sub");
        var claimed = false;
        for (assoc.defaults) |d| claimed = claimed or std.mem.eql(u8, d, ext);
        try testing.expectEqual(claimed, assoc.isOurs(t.hive(), ext));
    }
    try testing.expect(!assoc.isOurs(t.hive(), "zip") and !assoc.isOurs(t.hive(), "iso") and assoc.isOurs(t.hive(), "7z"));
    try testing.expect(!t.exists("Software\\MakePack\\Prev")); // nobody owned anything before
    try testing.expect(!t.exists(classes ++ "*\\shell\\MakePack.Add")); // the file menu is --addmenu's
    try testing.expect(t.dword("Software\\MakePack", "MenuItems") == null); // never written by a registration
}

test "assoc: owners - dead and live, UserChoice, Prev, forced, and unregister restoring the previous owner" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();
    const gone = t.print("\"C:\\makepack-gone-{x}\\Other.exe\" \"%1\"", .{t.key.len * 7919});
    try t.set(classes ++ ".zip", null, "CompressedFolder");
    try t.set(classes ++ "CompressedFolder", null, "Compressed folder"); // no open command: not ours to judge = live
    try t.set(classes ++ ".rar", null, "Other.Rar");
    try t.set(classes ++ "Other.Rar\\shell\\open\\command", null, gone); // exe gone = dead
    try t.set(classes ++ ".gz", null, "Live.App");
    try t.set(classes ++ "Live.App\\shell\\open\\command", null, t.print("\"{s}\" \"%1\"", .{exePath(&t)}));
    try t.set(file_exts ++ ".7z\\UserChoice", "ProgId", "Live.App"); // a live user choice
    try t.set(file_exts ++ ".tar\\UserChoice", "ProgId", "Gone.App"); // a choice for an uninstalled app
    try t.set(file_exts ++ ".lzma\\UserChoice", "ProgId", assoc.prog_id); // ours: not foreign

    const gpa = testing.allocator;
    {
        const o = try assoc.owner(gpa, h, "zip");
        defer if (o.prog_id) |p| gpa.free(p);
        try testing.expectEqualStrings("CompressedFolder", o.prog_id.?);
        try testing.expect(!o.dead and !o.user_choice and !o.choice_dead);
    }
    {
        const o = try assoc.owner(gpa, h, "rar");
        defer if (o.prog_id) |p| gpa.free(p);
        try testing.expect(o.dead and !o.user_choice);
    }
    {
        const o = try assoc.owner(gpa, h, "7z");
        try testing.expect(o.prog_id == null and !o.dead and o.user_choice and !o.choice_dead);
    }
    {
        const o = try assoc.owner(gpa, h, "tar");
        try testing.expect(o.user_choice and o.choice_dead);
    }
    try testing.expect(!(try assoc.owner(gpa, h, "lzma")).user_choice);

    // Unforced: someone else's live default stays; verbs and Open-with are added anyway.
    try testing.expectEqual(assoc.Registered{ .default = false, .blocked = false }, try assoc.register(h, "zip", false));
    try expectStr("CompressedFolder", t.str(classes ++ ".zip", null));
    try expectStr("", t.str(classes ++ ".zip\\OpenWithProgids", assoc.prog_id));
    try testing.expect(t.exists(classes ++ "SystemFileAssociations\\.zip\\shell\\MakePack.Open"));
    try testing.expect(!(try assoc.register(h, "gz", false)).default);
    try expectStr("Live.App", t.str(classes ++ ".gz", null));
    // A dead owner is replaced and remembered.
    try testing.expect((try assoc.register(h, "rar", false)).default);
    try expectStr(assoc.prog_id, t.str(classes ++ ".rar", null));
    try expectStr("Other.Rar", t.str("Software\\MakePack\\Prev", ".rar"));
    // Free: claimed; a live UserChoice is left alone unless forced; a dead one goes.
    try testing.expect((try assoc.register(h, "7z", false)).default);
    try testing.expect(t.exists(file_exts ++ ".7z\\UserChoice"));
    try testing.expectEqual(assoc.Registered{ .default = true, .blocked = false }, try assoc.register(h, "tar", false));
    try testing.expect(!t.exists(file_exts ++ ".tar\\UserChoice") and t.exists(file_exts ++ ".tar"));
    // Forced: the live owner and the live choice give way.
    try testing.expect((try assoc.register(h, "zip", true)).default);
    try expectStr("CompressedFolder", t.str("Software\\MakePack\\Prev", ".zip"));
    try testing.expectEqual(assoc.Registered{ .default = true, .blocked = false }, try assoc.register(h, "7z", true));
    try testing.expect(!t.exists(file_exts ++ ".7z\\UserChoice"));
    _ = try assoc.register(h, "rar", true); // already ours: Prev keeps the real previous owner
    try expectStr("Other.Rar", t.str("Software\\MakePack\\Prev", ".rar"));

    try assoc.unregister(h, "rar");
    try expectStr("Other.Rar", t.str(classes ++ ".rar", null));
    try testing.expect(t.str("Software\\MakePack\\Prev", ".rar") == null);
    try testing.expect(t.str(classes ++ ".rar\\OpenWithProgids", assoc.prog_id) == null);
    try testing.expect(t.str("Software\\MakePack\\Capabilities\\FileAssociations", ".rar") == null);
    for ([_][]const u8{ "Open", "ExtractHere", "ExtractTo" }) |v|
        try testing.expect(!t.exists(t.print(classes ++ "SystemFileAssociations\\.rar\\shell\\MakePack.{s}", .{v})));
    try assoc.unregister(h, "zip");
    try expectStr("CompressedFolder", t.str(classes ++ ".zip", null));
    try assoc.unregister(h, "7z"); // nobody before: the default value goes
    try testing.expect(t.str(classes ++ ".7z", null) == null);
    try t.set(classes ++ ".tar", null, "Other.App"); // someone took it since: never touched
    try assoc.unregister(h, "tar");
    try expectStr("Other.App", t.str(classes ++ ".tar", null));
    try testing.expect(!t.exists(classes ++ "SystemFileAssociations\\.tar\\shell\\MakePack.Open"));
    try assoc.unregister(h, "cab"); // never registered: nothing to do, no error
}

test "assoc: --addmenu, quick format, profiles in the menu, ShellNew, applyMenu toggles" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const env = envFor(h, &aw.writer, &aw.writer, neverAsk);
    const profiles = [_]settings.Profile{
        .{ .Name = "Backup", .InMenu = true, .Format = .Zip },
        .{ .Name = "Off", .InMenu = false },
        .{ .Name = "Say \"hi\"", .InMenu = true }, // a quote would end the name in the command line
        .{ .Name = "Кожен", .InMenu = true, .Separate = true, .Sfx = true },
    };
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--addmenu", "on" }, &profiles));
    try testing.expectEqual(@as(?u32, 127), t.dword("Software\\MakePack", "MenuItems"));
    try expectStr("SevenZip", t.str("Software\\MakePack", "QuickFormat"));
    try expectStr(".7z", t.str("Software\\MakePack", "QuickExt"));

    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "*", "Directory" }) |parent| {
        const base = t.print(classes ++ "{s}\\shell\\MakePack.", .{parent});
        try expectVerb(&t, t.print("{s}Add", .{base}), S.tr().verbAddTo, " a \"%1\"");
        try expectStr("Player", t.str(t.print("{s}Add", .{base}), "MultiSelectModel"));
        try expectVerb(&t, t.print("{s}QuickAdd", .{base}), S.fillZ(&buf, S.tr().verbQuickAddFmt, .{".7z"}), " a --quick \"%1\"");
        try expectStr("Player", t.str(t.print("{s}QuickAdd", .{base}), "MultiSelectModel"));
        try expectVerb(&t, t.print("{s}P01", .{base}), S.fillZ(&buf, S.tr().verbProfileFmt, .{ ".zip", "Backup" }), " a --profile \"Backup\" \"%1\"");
        try expectStr("Player", t.str(t.print("{s}P01", .{base}), "MultiSelectModel"));
        try expectVerb(&t, t.print("{s}P02", .{base}), S.fillZ(&buf, S.tr().verbProfileSeparateFmt, .{ ".exe", "Кожен" }), " a --profile \"Кожен\" \"%1\"");
        try testing.expect(!t.exists(t.print("{s}P03", .{base})));
    }
    try expectStr("Backup", t.str("Software\\MakePack\\MenuProfiles\\01", "Name"));
    try expectStr(".zip", t.str("Software\\MakePack\\MenuProfiles\\01", "Ext"));
    try expectStr("0", t.str("Software\\MakePack\\MenuProfiles\\01", "Separate"));
    try expectStr("Кожен", t.str("Software\\MakePack\\MenuProfiles\\02", "Name"));
    try expectStr(".exe", t.str("Software\\MakePack\\MenuProfiles\\02", "Ext"));
    try expectStr("1", t.str("Software\\MakePack\\MenuProfiles\\02", "Separate"));
    try testing.expect(!t.exists("Software\\MakePack\\MenuProfiles\\03"));
    try testing.expectEqualSlices(u8, &assoc.empty_seven_zip, t.binary(classes ++ ".7z\\" ++ assoc.prog_id ++ "\\ShellNew", "Data").?);
    try testing.expect(!t.exists(classes ++ ".7z\\ShellNew")); // never under .7z itself

    // The quick format renames the item (and QuickExt for the DLL).
    try assoc.setQuickKind(h, .Zip);
    try assoc.applyMenu(h, &profiles);
    try expectStr(S.fillZ(&buf, S.tr().verbQuickAddFmt, .{".zip"}), t.str(classes ++ "*\\shell\\MakePack.QuickAdd", null));

    // Profiles are rewritten whole: a stale P05 and the dropped ones go.
    try t.set(classes ++ "*\\shell\\MakePack.P05", null, "stale");
    try t.set(classes ++ "*\\shell\\Other.Verb", null, "someone else's");
    try assoc.applyProfiles(h, profiles[0..1]);
    try testing.expect(t.exists(classes ++ "*\\shell\\MakePack.P01") and !t.exists(classes ++ "*\\shell\\MakePack.P02"));
    try testing.expect(!t.exists(classes ++ "*\\shell\\MakePack.P05") and t.exists(classes ++ "*\\shell\\Other.Verb"));
    try testing.expect(!t.exists("Software\\MakePack\\MenuProfiles\\02"));

    // Switching items off removes their keys; the registered types' verbs follow too.
    _ = try assoc.register(h, "7z", false);
    try assoc.setMenu(h, .{ .extract_here = true, .add = true });
    try assoc.applyMenu(h, &profiles);
    const sfa = classes ++ "SystemFileAssociations\\.7z\\shell\\MakePack.";
    try testing.expect(!t.exists(sfa ++ "Open") and t.exists(sfa ++ "ExtractHere") and !t.exists(sfa ++ "ExtractTo"));
    const pv = classes ++ assoc.prog_id ++ "\\shell\\MakePack.";
    try testing.expect(t.exists(pv ++ "ExtractHere") and !t.exists(pv ++ "ExtractTo"));
    try testing.expect(!t.exists(classes ++ "SystemFileAssociations\\.iso")); // not registered: untouched
    try testing.expect(t.exists(classes ++ "*\\shell\\MakePack.Add") and !t.exists(classes ++ "*\\shell\\MakePack.QuickAdd"));
    try testing.expect(!t.exists(classes ++ "*\\shell\\MakePack.P01") and !t.exists("Software\\MakePack\\MenuProfiles"));
    try testing.expect(!t.exists(classes ++ ".7z\\" ++ assoc.prog_id));

    // --addmenu off: the file/folder group goes, the archive verbs stay.
    try assoc.setMenu(h, .all_items);
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--addmenu", "off" }, &profiles));
    try testing.expectEqual(@as(?u32, 7), t.dword("Software\\MakePack", "MenuItems"));
    for ([_][]const u8{ "Add", "QuickAdd", "P01" }) |v| {
        try testing.expect(!t.exists(t.print(classes ++ "*\\shell\\MakePack.{s}", .{v})));
        try testing.expect(!t.exists(t.print(classes ++ "Directory\\shell\\MakePack.{s}", .{v})));
    }
    try testing.expect(!t.exists(classes ++ ".7z\\" ++ assoc.prog_id) and t.exists(sfa ++ "ExtractTo"));
    // Anything but "on" is off.
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--addmenu", "yes" }, &profiles));
    try testing.expect(!t.exists(classes ++ "*\\shell\\MakePack.Add"));

    // Language: the value for the menu DLL; this exe owns the registration, so the classic captions follow.
    const lang_saved = kit.i18n.current();
    defer kit.i18n.set(lang_saved);
    kit.i18n.set(.uk);
    try assoc.setLanguage(h, "uk", &profiles);
    try expectStr("uk", t.str("Software\\MakePack", "Language"));
    try expectStr(S.tr().verbExtractHere, t.str(sfa ++ "ExtractHere", null));
    kit.i18n.set(.en);
    try assoc.setLanguage(h, "Auto", &profiles);
    try expectStr("Auto", t.str("Software\\MakePack", "Language"));
    try expectStr("Extract here", t.str(sfa ++ "ExtractHere", null));
    // Another copy's registration (installed vs dev build) keeps its captions; only the value changes.
    try t.set(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null, "\"C:\\Other\\MakePack.exe\" \"%1\"");
    kit.i18n.set(.uk);
    try assoc.setLanguage(h, "pl", &profiles);
    try expectStr("pl", t.str("Software\\MakePack", "Language"));
    try expectStr("Extract here", t.str(sfa ++ "ExtractHere", null));
}

test "assoc: heal only reads a healthy registration, repairs a half-removed one, never hijacks another copy" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();
    try assoc.heal(h); // nothing registered: nothing written
    try testing.expect(reg.openKey(.hkcu, t.key, .{}) == error.NotFound);

    try t.set(classes ++ ".7z", null, assoc.prog_id); // an extension still points at us, the ProgID is gone
    try assoc.heal(h);
    try expectStr(t.print("\"{s}\" \"%1\"", .{exePath(&t)}), t.str(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null));
    try expectStr("Software\\MakePack\\Capabilities", t.str("Software\\RegisteredApplications", "MakePack"));

    try t.set("Software\\MakePack\\Capabilities", "ApplicationName", "Changed"); // healthy: heal must only read
    try assoc.heal(h);
    try expectStr("Changed", t.str("Software\\MakePack\\Capabilities", "ApplicationName"));

    const notepad = t.print("\"{s}\\notepad.exe\" \"%1\"", .{(try reg.getEnv(t.arena.allocator(), "SystemRoot")).?});
    try t.set(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null, notepad); // another copy of MakePack
    try assoc.heal(h);
    try expectStr(notepad, t.str(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null));

    try t.set(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null, "\"C:\\makepack-moved-away\\MakePack.exe\" \"%1\"");
    try assoc.heal(h); // the exe was moved: rewritten
    try expectStr("MakePack", t.str("Software\\MakePack\\Capabilities", "ApplicationName"));
    try expectStr(t.print("\"{s}\" \"%1\"", .{exePath(&t)}), t.str(classes ++ assoc.prog_id ++ "\\shell\\open\\command", null));

    try t.set("Software\\RegisteredApplications", "MakePack", ""); // Capabilities link lost
    try t.set("Software\\MakePack\\Capabilities", "ApplicationName", "Changed");
    try assoc.heal(h);
    try expectStr("MakePack", t.str("Software\\MakePack\\Capabilities", "ApplicationName"));
}

test "assoc: --unregister (no list) removes everything and restores previous owners" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const env = envFor(h, &aw.writer, &aw.writer, neverAsk);
    const profiles = [_]settings.Profile{.{ .Name = "Backup", .InMenu = true }};
    try t.set(classes ++ ".rar", null, "Other.Rar"); // dead owner: claimed, remembered in Prev
    try t.set("Software\\RegisteredApplications", "Other", "Software\\Other\\Capabilities");
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{"--register"}, &.{})); // no list = defaults
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--register", "zip" }, &.{}));
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--addmenu", "on" }, &profiles));
    try expectStr("Other.Rar", t.str("Software\\MakePack\\Prev", ".rar"));
    try testing.expect(assoc.isOurs(h, "zip") and t.exists(classes ++ "*\\shell\\MakePack.P01"));

    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{"--unregister"}, &profiles));
    try testing.expectEqualStrings("", aw.written());
    try expectStr("Other.Rar", t.str(classes ++ ".rar", null));
    for (assoc.all) |ext| {
        try testing.expect(!assoc.isOurs(h, ext));
        try testing.expect(!t.exists(t.print(classes ++ "SystemFileAssociations\\.{s}\\shell\\MakePack.Open", .{ext})));
        try testing.expect(t.str(t.print(classes ++ ".{s}\\OpenWithProgids", .{ext}), assoc.prog_id) == null);
    }
    try testing.expect(!t.exists(classes ++ assoc.prog_id));
    try testing.expect(!t.exists("Software\\MakePack"));
    try testing.expect(t.str("Software\\RegisteredApplications", "MakePack") == null);
    try expectStr("Software\\Other\\Capabilities", t.str("Software\\RegisteredApplications", "Other"));
    for ([_][]const u8{ "*", "Directory" }) |parent| for ([_][]const u8{ "Add", "QuickAdd", "P01" }) |v|
        try testing.expect(!t.exists(t.print(classes ++ "{s}\\shell\\MakePack.{s}", .{ parent, v })));
    try testing.expect(!t.exists(classes ++ ".7z\\" ++ assoc.prog_id));
}

test "assoc: registryVerb lists (trim, dots, case, empties), single unregister, failure = 1 with the message" {
    var t = try TestHive.init();
    defer t.deinit();
    const h = t.hive();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const env = envFor(h, &aw.writer, &aw.writer, neverAsk);
    try t.set(classes ++ ".rar", null, "Live.App");
    try t.set(classes ++ "Live.App", null, "x");
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--register", " .7Z, rar ,,." }, &.{}));
    try testing.expect(assoc.isOurs(h, "7z") and assoc.isOurs(h, "rar")); // forced
    try testing.expect(!assoc.isOurs(h, "tar") and !t.exists(classes ++ ".tar"));
    try expectStr("Live.App", t.str("Software\\MakePack\\Prev", ".rar"));
    try testing.expectEqual(@as(u8, 0), cli.registryVerb(env, &.{ "--unregister", "7Z" }, &.{}));
    try testing.expect(!assoc.isOurs(h, "7z") and assoc.isOurs(h, "rar"));
    try testing.expect(t.exists(classes ++ assoc.prog_id));

    // A registry failure: exit 1, the message on stdout (here: a key name over the 255-character limit).
    var long: [300]u8 = @splat('x');
    const bad_hive: assoc.Hive = .{ .prefix = t.print("{s}{s}\\", .{ t.prefix, &long }) };
    try testing.expectEqual(@as(u8, 1), cli.registryVerb(envFor(bad_hive, &aw.writer, &aw.writer, neverAsk), &.{ "--register", "7z" }, &.{}));
    try testing.expect(aw.written().len > 2);
}

// ---- single instance -----------------------------------------------------------------------------------

test "single: session name, line framing" {
    var buf: [32]u8 = undefined;
    const sid = try reg.sessionId(kit.w.GetCurrentProcessId());
    var want: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&want, "MakePack-{d}", .{sid}), single.sessionName(&buf));

    const lines = try single.splitLines(testing.allocator, "x\r\n\r\nC:\\a b\\Їжак.7z\n--here\rlast");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("C:\\a b\\Їжак.7z", lines[1]);
    try testing.expectEqualStrings("last", lines[3]);
    const none = try single.splitLines(testing.allocator, "\r\n\r\n");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

fn testName(buf: *[64]u8) []const u8 {
    var r: [8]u8 = undefined;
    testing.io.random(&r);
    return std.mem.print(buf, "MakePackTest-{x}", .{std.mem.readInt(u64, &r, .little)}) catch unreachable;
}

test "single: mutex - first owns, second is a client, an abandoned one is taken over" {
    var nb: [64]u8 = undefined;
    const name = testName(&nb);
    var first = try single.Instance.acquire(name);
    try testing.expect(first.server);
    const Other = struct {
        fn run(n: []const u8, out: *?single.Instance, release: bool) void {
            var i = single.Instance.acquire(n) catch return;
            out.* = i;
            if (release) i.release(); // else: the thread ends owning it = abandoned
        }
    };
    var seen: ?single.Instance = null;
    var th = try std.Thread.spawn(.{}, Other.run, .{ name, &seen, true });
    th.join();
    try testing.expect(seen != null and !seen.?.server);
    first.release();

    seen = null;
    th = try std.Thread.spawn(.{}, Other.run, .{ name, &seen, false });
    th.join();
    try testing.expect(seen.?.server);
    var after = try single.Instance.acquire(name); // the owner died without releasing
    try testing.expect(after.server);
    after.release();
    _ = kit.w.CloseHandle(seen.?.mutex); // the dead thread's handle
}

const Captured = struct {
    arena: std.heap.ArenaAllocator,
    lists: std.ArrayList([]const []const u8) = .empty,

    fn handler(c: *Captured) single.Handler {
        return .{ .ctx = c, .f = got };
    }

    fn got(ctx: ?*anyopaque, args: []const []const u8) void {
        const c: *Captured = @ptrCast(@alignCast(ctx.?));
        const a = c.arena.allocator();
        const copy = a.alloc([]const u8, args.len) catch return;
        for (args, copy) |s, *d| d.* = a.dupe(u8, s) catch return;
        c.lists.append(a, copy) catch return;
    }
};

test "single: pipe round trip - UTF-8 lines, one connection per invocation, empty list = show the window" {
    var nb: [64]u8 = undefined;
    const name = testName(&nb);
    var cap: Captured = .{ .arena = .init(testing.allocator) };
    defer cap.arena.deinit();
    const pipe = try reg.toW(testing.allocator, try std.mem.concat(cap.arena.allocator(), u8, &.{ "\\\\.\\pipe\\", name }));
    defer testing.allocator.free(pipe);
    const Server = struct {
        fn run(p: [:0]const u16, h: single.Handler) void {
            for (0..2) |_| single.serveOne(testing.allocator, p, h) catch return;
        }
    };
    const th = try std.Thread.spawn(.{}, Server.run, .{ pipe, cap.handler() });
    const sent = [_][]const u8{ "x", "C:\\Тека з пробілом\\архів.7z", "--here" };
    try testing.expect(single.send(testing.allocator, name, &sent));
    try testing.expect(single.send(testing.allocator, name, &.{}));
    th.join();
    try testing.expectEqual(@as(usize, 2), cap.lists.items.len);
    try testing.expectEqual(@as(usize, 3), cap.lists.items[0].len);
    for (sent, cap.lists.items[0]) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 0), cap.lists.items[1].len);
}

var served: Captured = .{ .arena = .init(std.heap.page_allocator) };

test "single: a client that wrote and closed before ConnectNamedPipe (ERROR_NO_DATA) is still heard" {
    var nb: [64]u8 = undefined;
    const name = testName(&nb);
    var cap: Captured = .{ .arena = .init(testing.allocator) };
    defer cap.arena.deinit();
    const pipe = try reg.toW(testing.allocator, try std.mem.concat(cap.arena.allocator(), u8, &.{ "\\\\.\\pipe\\", name }));
    defer testing.allocator.free(pipe);
    const h = try single.createPipe(pipe);
    defer _ = kit.w.CloseHandle(h);
    try testing.expect(single.send(testing.allocator, name, &.{ "x", "C:\\a.7z" })); // connects, writes, closes
    try single.accept(testing.allocator, h, cap.handler()); // only now the server gets to it
    try testing.expectEqual(@as(usize, 1), cap.lists.items.len);
    try testing.expectEqualStrings("C:\\a.7z", cap.lists.items[0][1]);
}

test "single: the name is ours alone, and a client that never closes is dropped after the read timeout" {
    var nb: [64]u8 = undefined;
    const name = testName(&nb);
    var cap: Captured = .{ .arena = .init(testing.allocator) };
    defer cap.arena.deinit();
    const pipe = try reg.toW(testing.allocator, try std.mem.concat(cap.arena.allocator(), u8, &.{ "\\\\.\\pipe\\", name }));
    defer testing.allocator.free(pipe);
    const h = try single.createPipe(pipe);
    defer _ = kit.w.CloseHandle(h);
    try testing.expectError(error.PipeFailed, single.createPipe(pipe)); // FILE_FLAG_FIRST_PIPE_INSTANCE
    const c = kit.w.CreateFileW(pipe.ptr, @bitCast(@as(i32, kit.w.GENERIC_WRITE)), 0, null, kit.w.OPEN_EXISTING, 0, null);
    try testing.expect(c != kit.w.INVALID_HANDLE_VALUE);
    defer _ = kit.w.CloseHandle(c);
    var put: kit.w.DWORD = 0;
    _ = kit.w.WriteFile(c, "x\r\n", 3, &put, null); // ... and then never closes
    const t0 = kit.w.GetTickCount64();
    try testing.expectError(error.PipeFailed, single.accept(testing.allocator, h, cap.handler()));
    try testing.expect(kit.w.GetTickCount64() - t0 < 8000);
    try testing.expectEqual(@as(usize, 0), cap.lists.items.len);
}

test "single: serve keeps accepting; send gives up after 1.5 s when nobody listens" {
    var nb: [64]u8 = undefined;
    const name = testName(&nb);
    // ponytail: the detached server thread stays blocked in ConnectNamedPipe until the test process exits.
    try single.serve(std.heap.page_allocator, name, served.handler());
    try testing.expect(single.send(testing.allocator, name, &.{"one"}));
    try testing.expect(single.send(testing.allocator, name, &.{ "two", "three" }));
    const t0 = kit.w.GetTickCount64();
    while (served.lists.items.len < 2 and kit.w.GetTickCount64() - t0 < 5000) kit.w.Sleep(10);
    try testing.expectEqual(@as(usize, 2), served.lists.items.len);
    try testing.expectEqualStrings("three", served.lists.items[1][1]);

    var nb2: [64]u8 = undefined;
    const start = kit.w.GetTickCount64();
    try testing.expect(!single.send(testing.allocator, testName(&nb2), &.{"lost"}));
    try testing.expect(kit.w.GetTickCount64() - start >= 1400);
}

test "single: absolute - paths travel absolute, verbs/switches/profile names stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(testing.io, a);
    const in = [_][]const u8{ "x", "rel\\a.7z", "--here", "-o", "out", "--sub" };
    const got = try single.absolute(a, &in);
    try testing.expectEqualStrings("x", got[0]);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cwd, "rel\\a.7z" }), got[1]);
    try testing.expectEqualStrings("--here", got[2]);
    try testing.expectEqualStrings("-o", got[3]);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cwd, "out" }), got[4]);
    try testing.expectEqualStrings("--sub", got[5]);
    try testing.expectEqualStrings("x", in[0]); // the input is not modified
    try testing.expectEqualStrings("rel\\a.7z", in[1]);

    const p = try single.absolute(a, &.{ "a", "--profile", "My Backup", "f.txt", "--quick" });
    try testing.expectEqualStrings("My Backup", p[2]);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cwd, "f.txt" }), p[3]);
    try testing.expectEqualStrings("--quick", p[4]);

    const r = try single.absolute(a, &.{ "arc.7z", "C:\\x", "\\\\srv\\s\\y", "C:rel", "/u", "" });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cwd, "arc.7z" }), r[0]); // no verb: the archive to open
    for ([_][]const u8{ "C:\\x", "\\\\srv\\s\\y", "C:rel", "/u", "" }, r[1..]) |want, g| try testing.expectEqualStrings(want, g);
    try testing.expectEqualStrings("convert", (try single.absolute(a, &.{"convert"}))[0]);
}

// ---- cli -------------------------------------------------------------------------------------------------

const Ran = struct {
    code: ?u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn deinit(r: *Ran) void {
        r.out.deinit();
        r.err.deinit();
    }
};

fn runCli(args: []const []const u8, ask: *const fn (Allocator, []const u8, ?[]const u8) ?[]u8) Ran {
    var r: Ran = .{ .code = null, .out = .init(testing.allocator), .err = .init(testing.allocator) };
    r.code = cli.run(envFor(.{}, &r.out.writer, &r.err.writer, ask), args);
    return r;
}

fn expectRun(want: u8, args: []const []const u8, ask: *const fn (Allocator, []const u8, ?[]const u8) ?[]u8, msg: []const u8) !void {
    var r = runCli(args, ask);
    defer r.deinit();
    if (r.code != want or std.mem.find(u8, r.err.written(), msg) == null) {
        std.debug.print("args {f}: exit {?d} (want {d}), stderr \"{s}\" (want \"{s}\")\n", .{ std.json.fmt(args, .{}), r.code, want, r.err.written(), msg });
        return error.TestUnexpectedResult;
    }
}

test "cli: which argument lists are scripts (the rest go to the GUI)" {
    const gui = [_][]const []const u8{
        &.{},                      &.{"t"},                          &.{"l"},              &.{ "x", "a.7z" }, &.{ "x", "a.7z", "--here" }, &.{ "a", "f.txt" },
        &.{ "a", "--quick", "f" }, &.{ "a", "--profile", "n", "f" }, &.{ "convert", "f" }, &.{"C:\\a.7z"},    &.{ "a", "" },
    };
    for (gui) |args| {
        try testing.expect(!cli.headless(args));
        var r = runCli(args, neverAsk);
        defer r.deinit();
        try testing.expect(r.code == null);
    }
    for ([_][]const []const u8{ &.{ "t", "a" }, &.{ "l", "a" }, &.{ "a", "-y" }, &.{ "x", "a", "-y" }, &.{ "a", "-m1", "a", "b" } }) |args|
        try testing.expect(cli.headless(args));
}

test "cli: exit codes and messages decided before the engine runs" {
    const saved = kit.i18n.current();
    defer kit.i18n.set(saved);
    kit.i18n.set(.en);
    var pv = try PasswordVar.set(null);
    defer pv.restore();
    var tmp = try testutil.TempDir.init(testing.allocator, testing.io);
    defer tmp.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try tmp.join("payload");
    try std.Io.Dir.cwd().createDirPath(testing.io, src);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ src, "one.txt" }), .data = "one" });
    const existing = try tmp.join("existing.7z");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = existing, .data = "not really" });
    const missing = try tmp.join("missing.7z");
    const out = try tmp.join("out.7z");
    defer for ([_][]u8{ src, existing, missing, out }) |s| testing.allocator.free(s);

    // 7: a password in the arguments (any case), unknown switches, the wrong number of archives.
    try expectRun(7, &.{ "t", "-pSecret", existing }, neverAsk, "MAKEPACK_PASSWORD");
    try expectRun(7, &.{ "t", "-P", existing }, neverAsk, "MAKEPACK_PASSWORD");
    try expectRun(7, &.{ "l", "-q", existing }, neverAsk, "Unknown or invalid switch: -q");
    try expectRun(7, &.{ "t", existing, "second.7z" }, neverAsk, "Unknown or invalid switch: second.7z");
    try expectRun(7, &.{ "t", "-p" }, neverAsk, "Unknown or invalid switch: <archive>");
    try expectRun(7, &.{ "x", "-y", existing, "-o" }, neverAsk, "Unknown or invalid switch: -o");
    try expectRun(7, &.{ "x", "-y", "--here", "-pX", existing }, neverAsk, "MAKEPACK_PASSWORD");
    try expectRun(7, &.{ "x", "-y", "--sub" }, neverAsk, "<archive>");
    try expectRun(7, &.{ "a", "-pSecret", out, src }, neverAsk, "MAKEPACK_PASSWORD");
    try expectRun(7, &.{ "a", "-hpSecret", out, src }, neverAsk, "MAKEPACK_PASSWORD");
    try expectRun(7, &.{ "a", "-tfoo", out, src }, neverAsk, "Unknown or invalid switch: -tfoo");
    try expectRun(7, &.{ "a", "-m6", out, src }, neverAsk, "-m6");
    try expectRun(7, &.{ "a", "-v0", out, src }, neverAsk, "-v0");
    try expectRun(7, &.{ "a", "-vabc", out, src }, neverAsk, "-vabc");
    try expectRun(7, &.{ "a", "-y", out }, neverAsk, "<files>");
    try expectRun(7, &.{ "a", "-y" }, neverAsk, "<archive>");
    try testing.expect(!pw.fileExists(out)); // nothing written by any of them

    // 10: no such archive / nothing matches.
    try expectRun(10, &.{ "t", missing }, neverAsk, try a.print("File not found: {s}", .{missing}));
    try expectRun(10, &.{ "l", missing }, neverAsk, "File not found");
    try expectRun(10, &.{ "x", "-y", missing, "-o", src }, neverAsk, "File not found");
    const nomatch = try std.fs.path.join(a, &.{ tmp.path, "nothing*.xyz" });
    try expectRun(10, &.{ "a", "-y", out, nomatch }, neverAsk, try a.print("Nothing matches: {s}", .{nomatch}));
    try expectRun(10, &.{ "a", "-y", out, missing }, neverAsk, "Nothing matches");

    // 2: an existing archive without -y.
    try expectRun(2, &.{ "a", "-m1", existing, src }, neverAsk, try a.print("{s} already exists. Add -y to overwrite it.", .{existing}));
    try testing.expect(pw.fileExists(existing));

    // Passwords for a: 255 when the prompt is cancelled, 11 when the two entries differ, 7 for a format without
    // encryption and for -hp outside 7z.
    try expectRun(255, &.{ "a", "-p", out, src }, neverAsk, S.tr().cancelled);
    ask_count = 0;
    try expectRun(11, &.{ "a", "-p", out, src }, askDiffer, "do not match");
    try testing.expectEqual(@as(usize, 2), ask_count);
    var pv2 = try PasswordVar.set("Secret");
    defer pv2.restore();
    try expectRun(7, &.{ "a", "-p", "-ttar", out, src }, neverAsk, "The tar format does not support passwords.");
    try expectRun(7, &.{ "a", "-hp", "-tzip", out, src }, neverAsk, "MAKEPACK_PASSWORD");
    try testing.expect(!pw.fileExists(out));
}

test "cli: planAdd - kind from -t or the name, extension, masks, password only with -p, -y" {
    var pv = try PasswordVar.set(null);
    defer pv.restore();
    var tmp = try testutil.TempDir.init(testing.allocator, testing.io);
    defer tmp.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const d = std.Io.Dir.cwd();
    const p = struct {
        fn at(ar: Allocator, dir: []const u8, name: []const u8) []const u8 {
            return std.fs.path.join(ar, &.{ dir, name }) catch unreachable;
        }
    }.at;
    for ([_][]const u8{ "a.txt", "B.TXT", "c.bin", "a.txt~" }) |n| try d.writeFile(io, .{ .sub_path = p(a, tmp.path, n), .data = n });
    try d.createDirPath(io, p(a, tmp.path, "d.txt"));
    var diag: engine.Diag = .{};
    var nul: std.Io.Writer.Discarding = .init(&.{});
    const env = envFor(.{}, &nul.writer, &nul.writer, neverAsk);

    var plan = try cli.planAdd(env, a, &.{ "-M5", "-t7z", p(a, tmp.path, "out.zip"), p(a, tmp.path, "c.bin") }, &diag);
    try testing.expectEqual(types.ArchiveKind.SevenZip, plan.kind);
    try testing.expectEqualStrings(p(a, tmp.path, "out.zip"), plan.archive); // has an extension: kept
    try testing.expectEqual(types.CompressionLevel.Ultra, plan.options.level);
    try testing.expect(plan.options.password == null and !plan.options.encrypt_headers and plan.options.volume_size == 0);
    try testing.expectEqual(types.CompressionMethod.Default, plan.options.method);
    try testing.expect(!plan.replace);

    plan = try cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "out"), p(a, tmp.path, "*.txt") }, &diag);
    try testing.expectEqual(types.ArchiveKind.SevenZip, plan.kind);
    try testing.expectEqual(types.CompressionLevel.Normal, plan.options.level);
    try testing.expectEqualStrings(p(a, tmp.path, "out.7z"), plan.archive);
    try testing.expectEqual(@as(usize, 3), plan.inputs.len); // a.txt, B.TXT and the folder d.txt; not a.txt~
    for (plan.inputs) |in| try testing.expect(std.ascii.endsWithIgnoreCase(in, ".txt"));

    plan = try cli.planAdd(env, a, &.{ "-ttgz", p(a, tmp.path, "x"), p(a, tmp.path, "*.*") }, &diag);
    try testing.expectEqual(types.ArchiveKind.TarGz, plan.kind);
    try testing.expectEqualStrings(p(a, tmp.path, "x.tar.gz"), plan.archive);
    try testing.expectEqual(@as(usize, 5), plan.inputs.len);
    plan = try cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "x.TAR.GZ"), p(a, tmp.path, "?.bin") }, &diag);
    try testing.expectEqual(types.ArchiveKind.TarGz, plan.kind); // the longest known extension wins
    try testing.expectEqual(@as(usize, 1), plan.inputs.len);
    plan = try cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "x.tar.Xz"), tmp.path }, &diag);
    try testing.expectEqual(types.ArchiveKind.TarXz, plan.kind);
    try testing.expectEqualStrings(tmp.path, plan.inputs[0]);
    plan = try cli.planAdd(env, a, &.{ "-tTBZ2", p(a, tmp.path, "x"), tmp.path }, &diag);
    try testing.expectEqualStrings(p(a, tmp.path, "x.tar.bz2"), plan.archive);
    plan = try cli.planAdd(env, a, &.{ "-ttxz", p(a, tmp.path, "x"), tmp.path }, &diag);
    try testing.expectEqualStrings(p(a, tmp.path, "x.tar.xz"), plan.archive);
    for ([_][]const u8{ "-m0", "-m1", "-m2", "-m3", "-m4", "-m5" }, 0..) |sw, lvl| {
        plan = try cli.planAdd(env, a, &.{ sw, p(a, tmp.path, "lv"), tmp.path }, &diag);
        try testing.expectEqual(@as(u8, @intCast(lvl)), @backingInt(plan.options.level));
    }
    plan = try cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "a.txt"), tmp.path }, &diag); // a known file, unknown kind
    try testing.expectEqual(types.ArchiveKind.SevenZip, plan.kind);
    try testing.expectEqualStrings(p(a, tmp.path, "a.txt"), plan.archive);
    try testing.expect(plan.replace); // it exists and -y was given
    try testing.expectError(error.AlreadyExists, cli.planAdd(env, a, &.{ "-m1", p(a, tmp.path, "a.txt"), tmp.path }, &diag));
    try testing.expectError(error.FileNotFound, cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "o"), "-m1" }, &diag)); // after the name: an input
    try testing.expectEqual(@as(u8, 10), engine.exitCodeOf(error.FileNotFound));

    // MAKEPACK_PASSWORD: used with -p/-hp (never asking), ignored without.
    var pv2 = try PasswordVar.set("Secret");
    defer pv2.restore();
    plan = try cli.planAdd(env, a, &.{ "-y", p(a, tmp.path, "o"), tmp.path }, &diag);
    try testing.expect(plan.options.password == null);
    plan = try cli.planAdd(env, a, &.{ "-hp", p(a, tmp.path, "o"), tmp.path }, &diag);
    try testing.expectEqualStrings("Secret", plan.options.password.?);
    try testing.expect(plan.options.encrypt_headers);
    plan = try cli.planAdd(env, a, &.{ "-p", "-tzip", p(a, tmp.path, "o"), tmp.path }, &diag);
    try testing.expectEqualStrings("Secret", plan.options.password.?);
    try testing.expect(!plan.options.encrypt_headers);
}

test "cli: planAdd volumes (-v) check the first part" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pv = try PasswordVar.set(null);
    defer pv.restore();
    var tmp = try testutil.TempDir.init(testing.allocator, testing.io);
    defer tmp.deinit();
    var diag: engine.Diag = .{};
    var nul: std.Io.Writer.Discarding = .init(&.{});
    const env = envFor(.{}, &nul.writer, &nul.writer, neverAsk);
    const arc = try std.fs.path.join(a, &.{ tmp.path, "set.7z" });
    var plan = try cli.planAdd(env, a, &.{ "-v100k", arc, tmp.path }, &diag);
    try testing.expectEqual(@as(i64, 100 << 10), plan.options.volume_size);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try engine.part(a, arc, 1), .data = "x" });
    try testing.expectError(error.AlreadyExists, cli.planAdd(env, a, &.{ "-v100k", arc, tmp.path }, &diag));
    plan = try cli.planAdd(env, a, &.{ "-v100k", "-y", arc, tmp.path }, &diag);
    try testing.expect(!plan.replace); // a set is replaced part by part by compress itself
}

test "cli: open decisions - encrypted file list without a password = 11, given up front = used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nul: std.Io.Writer.Discarding = .init(&.{});
    const env = envFor(.{}, &nul.writer, &nul.writer, neverAsk);
    var pv = try PasswordVar.set(null);
    defer pv.restore();

    try testing.expectError(error.PasswordNeeded, cli.passwordFor(env, a, "C:\\x.7z", .encrypted_headers, false));
    try testing.expectEqual(@as(u8, 11), engine.exitCodeOf(error.PasswordNeeded));
    try testing.expectError(error.Canceled, cli.passwordFor(env, a, "C:\\x.7z", .encrypted_headers, true));
    try testing.expectError(error.NotAnArchive, cli.passwordFor(env, a, "C:\\x.7z", .not_archive, true));
    try testing.expectEqual(@as(u8, 2), engine.exitCodeOf(error.NotAnArchive));
    try testing.expectError(error.Damaged, cli.passwordFor(env, a, "C:\\x.7z", .damaged, false));
    try testing.expectEqual(@as(u8, 3), engine.exitCodeOf(error.Damaged));
    try testing.expect(try cli.passwordFor(env, a, "C:\\x.7z", .archive, false) == null);
    ask_count = 0;
    var asking = env;
    asking.ask_password = askSame;
    try testing.expectEqualStrings("pw", (try cli.passwordFor(asking, a, "C:\\x.7z", .archive, true)).?);
    try testing.expectEqual(@as(usize, 1), ask_count); // no confirmation when opening

    var pv2 = try PasswordVar.set("Secret");
    defer pv2.restore();
    try testing.expectEqualStrings("Secret", (try cli.passwordFor(env, a, "C:\\x.7z", .encrypted_headers, false)).?);
    try testing.expectEqualStrings("Secret", (try cli.passwordFor(env, a, "C:\\x.7z", .archive, false)).?);
}

test "cli: parse t/l/x" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: engine.Diag = .{};
    const o = try cli.parseOne(a, &.{ "-p", "arc.7z" }, &diag);
    try testing.expect(o.ask and std.mem.eql(u8, o.archive, "arc.7z"));
    const x = try cli.parseExtract(a, &.{ "-y", "arc.7z", "-o", "-p", "--here" }, &diag);
    try testing.expect(x.ask and !x.sub and std.mem.eql(u8, x.dest.?, "-p") and std.mem.eql(u8, x.archive, "arc.7z"));
    const s = try cli.parseExtract(a, &.{ "--sub", "-y", "arc.7z" }, &diag);
    try testing.expect(s.sub and !s.ask and s.dest == null);

    // Where x puts things: -o wins over --sub; otherwise the folder of the archive's full path.
    // (--sub's Engine.BaseName part is checked in the end-to-end test: baseName is MP-B's.)
    const cwd = try std.process.currentPathAlloc(testing.io, a);
    try testing.expectEqualStrings("D:\\o", try cli.extractDest(a, .{ .archive = "x.7z", .ask = false, .dest = "D:\\o", .sub = true }));
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cwd, "rel" }), try cli.extractDest(a, .{ .archive = "rel\\x.tar.gz", .ask = false, .dest = null, .sub = false }));
    try testing.expectEqualStrings("C:\\d", try cli.extractDest(a, .{ .archive = "C:\\d\\x.7z", .ask = false, .dest = null, .sub = false }));
}

test "cli: a -y moves the old archive aside and puts it back when compress fails" {
    var tmp = try testutil.TempDir.init(testing.allocator, testing.io);
    defer tmp.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const d = std.Io.Dir.cwd();
    const arc = try std.fs.path.join(a, &.{ tmp.path, "x.7z" });
    const old = try std.mem.concat(a, u8, &.{ arc, ".makepack~" });
    try d.writeFile(io, .{ .sub_path = arc, .data = "precious" });
    try d.writeFile(io, .{ .sub_path = old, .data = "an older backup" });

    const b = try cli.moveAside(io, a, arc);
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ arc, ".makepack~2" }), b); // never over an older one
    try testing.expect(!pw.fileExists(arc));
    try d.writeFile(io, .{ .sub_path = arc, .data = "half-written" }); // what a failed compress may leave
    cli.putBack(io, b, arc);
    try testing.expectEqualStrings("precious", try d.readFileAlloc(io, arc, a, .limited(64)));
    try testing.expect(!pw.fileExists(b));
    try testing.expectEqualStrings("an older backup", try d.readFileAlloc(io, old, a, .limited(64)));

    // Through run(): a compress that fails after the move (gz takes one file only) leaves the old archive untouched.
    var pv = try PasswordVar.set(null);
    defer pv.restore();
    {
        var r = runCli(&.{ "a", "-y", "-tgz", arc, tmp.path }, neverAsk);
        defer r.deinit();
        try testing.expect(r.code != null and r.code.? != 0);
    }
    try testing.expectEqualStrings("precious", try d.readFileAlloc(io, arc, a, .limited(64)));
    try testing.expect(!pw.fileExists(try std.mem.concat(a, u8, &.{ arc, ".makepack~2" })));

    // The archive inside its own sources (C#: works): replaced, and the backup is not packed into the new archive.
    {
        var r = runCli(&.{ "a", "-y", arc, tmp.path }, neverAsk);
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    try testing.expect(!pw.fileExists(try std.mem.concat(a, u8, &.{ arc, ".makepack~2" })));
    var l = runCli(&.{ "l", arc }, neverAsk);
    defer l.deinit();
    try testing.expectEqual(@as(?u8, 0), l.code);
    try testing.expect(std.mem.find(u8, l.out.written(), "makepack~") == null);
}

// ---- cli end to end through the real engine (7z.exe as the oracle) ------------------------------------------

test "cli end to end: a / t / l / x -y with 7z.exe as the oracle" {
    const paths = @import("paths");
    try needEngine();
    const saved = kit.i18n.current();
    defer kit.i18n.set(saved);
    kit.i18n.set(.en);
    var pv = try PasswordVar.set(null);
    defer pv.restore();
    var tmp = try testutil.TempDir.init(testing.allocator, testing.io);
    defer tmp.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const at = struct {
        fn f(ar: Allocator, dir: []const u8, name: []const u8) []const u8 {
            return std.fs.path.join(ar, &.{ dir, name }) catch unreachable;
        }
    }.f;
    const big: [8000]u8 = @splat('t');
    const src = at(a, tmp.path, "payload");
    try std.Io.Dir.cwd().createDirPath(io, src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = at(a, src, "one.txt"), .data = &big });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = at(a, src, "два.txt"), .data = "two" });

    const arc = at(a, tmp.path, "out.7z");
    try expectRun(0, &.{ "a", "-m1", arc, src }, neverAsk, "");
    {
        var r = runCli(&.{ "t", arc }, neverAsk);
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expectEqualStrings("The archive is OK.\r\n", r.out.written());
    }
    {
        var r = runCli(&.{ "l", arc }, neverAsk);
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(std.mem.find(u8, r.out.written(), "one.txt") != null and std.mem.find(u8, r.out.written(), "два.txt") != null);
    }
    const dst = at(a, tmp.path, "x");
    try expectRun(0, &.{ "x", "-y", arc, "-o", dst }, neverAsk, "");
    try testing.expect(pw.fileExists(at(a, dst, "payload\\два.txt")));
    try expectRun(0, &.{ "x", "-y", arc, "-o", dst }, neverAsk, ""); // again: overwrites quietly
    try expectRun(0, &.{ "x", "-y", "--sub", arc }, neverAsk, "");
    try testing.expect(pw.fileExists(at(a, tmp.path, "out\\payload\\one.txt")));
    try testing.expectEqualStrings(at(a, tmp.path, "x"), try cli.extractDest(a, .{ .archive = at(a, tmp.path, "x.tar.gz"), .ask = false, .dest = null, .sub = true }));

    // a -y over an existing archive: replaced, no backup left; a failing one (gz takes one file only) leaves the
    // old archive exactly as it was.
    try expectRun(0, &.{ "a", "-y", "-m1", arc, src }, neverAsk, "");
    try testing.expect(!pw.fileExists(at(a, tmp.path, "out.7z.makepack~")));
    const before = try std.Io.Dir.cwd().readFileAlloc(io, arc, a, .limited(1 << 20));
    {
        var r = runCli(&.{ "a", "-y", "-tgz", arc, src }, neverAsk);
        defer r.deinit();
        try testing.expect(r.code != null and r.code.? != 0);
    }
    try testing.expectEqualSlices(u8, before, try std.Io.Dir.cwd().readFileAlloc(io, arc, a, .limited(1 << 20)));
    try testing.expect(!pw.fileExists(at(a, tmp.path, "out.7z.makepack~")));

    // 3: damaged (a few bytes of the packed file data overwritten; any further and the archive is this small that
    // the packed header stream behind the data is hit too - then 7z.exe cannot open it either, and the result is 11).
    const bad_arc = at(a, tmp.path, "bad.7z");
    const damaged = try a.dupe(u8, before);
    @memset(damaged[34..40], 0x5a);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_arc, .data = damaged });
    {
        var r = runCli(&.{ "t", bad_arc }, neverAsk);
        defer r.deinit();
        try testing.expectEqual(@as(?u8, 3), r.code);
    }

    // 2: not an archive; 11: encrypted file list without a password, 0 with the right one.
    const txt = at(a, tmp.path, "plain.txt");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = txt, .data = &big });
    try expectRun(2, &.{ "t", txt }, neverAsk, "");
    const enc = at(a, tmp.path, "enc.7z");
    const r7 = try std.process.run(a, io, .{ .argv = &.{ paths.seven_zip_exe, "a", "-t7z", "-pSecret", "-mhe=on", enc, src, "-bso0", "-bsp0" } });
    try testing.expect(r7.term == .exited and r7.term.exited == 0);
    try expectRun(11, &.{ "t", enc }, neverAsk, "Add -p to enter it.");
    var pv2 = try PasswordVar.set("WrongPass");
    defer pv2.restore();
    try expectRun(11, &.{ "t", enc }, neverAsk, "Wrong password");
    var pv3 = try PasswordVar.set("Secret");
    defer pv3.restore();
    try expectRun(0, &.{ "t", enc }, neverAsk, "");
}
