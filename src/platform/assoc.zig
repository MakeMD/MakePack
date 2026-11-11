//! MP-C: every registry write MakePack makes (Assoc.cs): the ProgID, per-extension verbs, the "Add to
//! archive" items, Explorer's New > MakePack archive, the profiles' menu items.
//!
//! The keys and values are an external contract: shell/ (MakePackShell, reads Software\MakePack MenuItems,
//! QuickExt, MenuProfiles\NN Name/Ext/Separate) and installer/MakePack.iss depend on them - same names,
//! types (MenuItems = REG_DWORD, QuickFormat = ArchiveKind member name, ShellNew Data = REG_BINARY).
//! ponytail (from C#): per-user (HKCU) only; all-users needs the same keys under HKLM plus elevation.
//!
//! SAFETY: the C# MakePack is installed on the dev machine. Tests use `Hive{ .prefix = <testutil.regTestKey> }`
//! and delete that key afterwards; nothing in a test may touch the real Software\Classes, Software\MakePack or
//! RegisteredApplications.
const std = @import("std");
const kit = @import("kit");
const types = @import("../core/types.zig");
const settings = @import("../settings.zig");
const S = @import("../strings.zig");
const pw = @import("platform_win.zig");

const Allocator = std.mem.Allocator;
const reg = kit.win;
const eql = std.mem.eql;

pub const prog_id = "MakePack.Archive";

/// Assoc.All / Assoc.Defaults
pub const all = types.archive_exts;
pub const defaults = types.default_exts;

const classes = "Software\\Classes\\";
const root = "Software\\MakePack"; // also read by the shell DLL: MenuItems, QuickExt
const caps = "Software\\MakePack\\Capabilities";
const prev_key = "Software\\MakePack\\Prev";
const file_exts = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\";
const reg_apps = "Software\\RegisteredApplications";
/// MenuProfiles\01..: Name, Ext, Separate - read by the DLL.
const menu_profiles = root ++ "\\MenuProfiles";
/// Under our ProgID, not .7z itself: Explorer only looks there while .7z is MakePack's.
const shell_new_key = classes ++ ".7z\\" ++ prog_id;

/// Explorer menu items the user can switch off (C# [Flags] enum MenuItems; the DWORD's bits).
/// A missing MenuItems value = all on.
pub const MenuItems = packed struct(u32) {
    open: bool = false, // 1
    extract_here: bool = false, // 2
    extract_to: bool = false, // 4
    add: bool = false, // 8
    quick_add: bool = false, // 16
    new: bool = false, // 32
    /// The items of the profiles marked "in menu" (each still needs that mark). 64
    profiles: bool = false,
    _: u25 = 0,

    pub const none: MenuItems = .{};
    pub const all_items: MenuItems = .{ .open = true, .extract_here = true, .extract_to = true, .add = true, .quick_add = true, .new = true, .profiles = true };
    /// What --addmenu on|off switches: the items on every file and folder.
    pub const files: MenuItems = .{ .add = true, .quick_add = true, .new = true, .profiles = true };
};

/// Where Assoc reads and writes. `.{}` = the real thing: HKCU, plus HKCR for the merged reads (Owner, Dead,
/// IsOurs). Tests: `.{ .prefix = "Software\\MakePackTest-1a2b\\" }` - every HKCU path gets the prefix, and
/// the HKCR reads become HKCU reads of prefix ++ "Software\\Classes\\" ++ key.
pub const Hive = struct { prefix: []const u8 = "" };

// ---- primitives ------------------------------------------------------------------------------------
// One public call = one Ctx with a scratch arena for the paths and values it reads.

const Ctx = struct {
    h: Hive,
    a: Allocator,

    fn cat(c: Ctx, parts: []const []const u8) ![]const u8 {
        return std.mem.concat(c.a, u8, parts);
    }

    /// An HKCU path under the hive.
    fn path(c: Ctx, key: []const u8) ![]const u8 {
        return c.cat(&.{ c.h.prefix, key });
    }

    fn set(c: Ctx, key: []const u8, name: ?[]const u8, value: []const u8) !void {
        const k = try reg.createKey(.hkcu, try c.path(key), .default);
        defer k.close();
        try k.writeString(name, value);
    }

    fn delValue(c: Ctx, key: []const u8, name: []const u8) void {
        const k = reg.openKey(.hkcu, c.path(key) catch return, .{ .write = true }) catch return;
        defer k.close();
        k.deleteValue(name) catch {};
    }

    fn delTree(c: Ctx, key: []const u8) void {
        reg.deleteKeyTree(.hkcu, c.path(key) catch return, .default) catch {};
    }

    /// Registry.CurrentUser: the string value; null when the key or value is missing or not a string.
    fn read(c: Ctx, key: []const u8, name: ?[]const u8) ?[]u8 {
        return readAt(c.a, .hkcu, c.path(key) catch return null, name);
    }

    fn exists(c: Ctx, key: []const u8) bool {
        return existsAt(.hkcu, c.path(key) catch return false);
    }

    /// Registry.ClassesRoot = HKCU over HKLM, which is what Explorer sees. Under a test prefix: the
    /// prefix's own Software\Classes only.
    fn readCr(c: Ctx, key: []const u8, name: ?[]const u8) ?[]u8 {
        if (c.h.prefix.len == 0) return readAt(c.a, .hkcr, key, name);
        return readAt(c.a, .hkcu, c.cat(&.{ c.h.prefix, classes, key }) catch return null, name);
    }

    fn existsCr(c: Ctx, key: []const u8) bool {
        if (c.h.prefix.len == 0) return existsAt(.hkcr, key);
        return existsAt(.hkcu, c.cat(&.{ c.h.prefix, classes, key }) catch return false);
    }

    /// Set(key, null, caption) + Icon + command: "<exe>"<args>.
    fn verb(c: Ctx, key: []const u8, caption: []const u8, args: []const u8) !void {
        const exe = try pw.exePath(c.a); // Environment.ProcessPath: the app may have been moved or reinstalled
        try c.set(key, null, caption);
        try c.set(key, "Icon", try c.cat(&.{ "\"", exe, "\",0" }));
        try c.set(try c.cat(&.{ key, "\\command" }), null, try c.cat(&.{ "\"", exe, "\"", args }));
    }

    /// The verb when `on`, no key at all when not.
    fn toggle(c: Ctx, key: []const u8, on: bool, caption: []const u8, args: []const u8) !void {
        if (on) try c.verb(key, caption, args) else c.delTree(key);
    }
};

fn readAt(a: Allocator, r: reg.Root, key: []const u8, name: ?[]const u8) ?[]u8 {
    const k = reg.openKey(r, key, .{}) catch return null;
    defer k.close();
    return k.readString(a, name) catch null;
}

fn existsAt(r: reg.Root, key: []const u8) bool {
    const k = reg.openKey(r, key, .{}) catch return false;
    k.close();
    return true;
}

/// A call's scratch arena (ponytail: page_allocator; registry work is a handful of short strings).
const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Scratch {
        return .{ .arena = .init(std.heap.page_allocator) };
    }
    fn ctx(s: *Scratch, h: Hive) Ctx {
        return .{ .h = h, .a = s.arena.allocator() };
    }
    fn deinit(s: *Scratch) void {
        s.arena.deinit();
    }
};

// ---- which menu items, and the quick-add format ------------------------------------------------------

/// Assoc.Menu (get). Missing or unreadable = all_items; unknown bits are masked off.
pub fn menu(h: Hive) MenuItems {
    var s = Scratch.init();
    defer s.deinit();
    return menuC(s.ctx(h));
}

fn menuC(c: Ctx) MenuItems {
    const k = reg.openKey(.hkcu, c.path(root) catch return .all_items, .{}) catch return .all_items;
    defer k.close();
    const v = k.readDword("MenuItems") catch return .all_items;
    return @bitCast(v & @as(u32, @bitCast(MenuItems.all_items)));
}

/// Assoc.Menu (set): Software\MakePack MenuItems as REG_DWORD.
pub fn setMenu(h: Hive, m: MenuItems) !void {
    var s = Scratch.init();
    defer s.deinit();
    return setMenuC(s.ctx(h), m);
}

fn setMenuC(c: Ctx, m: MenuItems) !void {
    const k = try reg.createKey(.hkcu, try c.path(root), .default);
    defer k.close();
    try k.writeDword("MenuItems", @bitCast(m));
}

/// Assoc.QuickKind (get): Software\MakePack QuickFormat (an ArchiveKind member name, case-sensitive like
/// Enum.TryParse, which also takes the member's number, "3"); a missing, unknown or single-file kind = SevenZip.
pub fn quickKind(h: Hive) types.ArchiveKind {
    var s = Scratch.init();
    defer s.deinit();
    return quickKindC(s.ctx(h));
}

fn quickKindC(c: Ctx) types.ArchiveKind {
    const v = c.read(root, "QuickFormat") orelse return .SevenZip;
    const t = std.mem.trim(u8, v, &std.ascii.whitespace);
    const k = std.meta.stringToEnum(types.ArchiveKind, t) orelse
        std.enums.fromInt(types.ArchiveKind, std.fmt.parseInt(i32, t, 10) catch return .SevenZip) orelse return .SevenZip;
    return if (types.kind(k).multi) k else .SevenZip;
}

/// Assoc.QuickKind (set): QuickFormat + QuickExt (the extension, for the Windows 11 menu DLL).
pub fn setQuickKind(h: Hive, k: types.ArchiveKind) !void {
    var s = Scratch.init();
    defer s.deinit();
    return setQuickKindC(s.ctx(h), k);
}

fn setQuickKindC(c: Ctx, k: types.ArchiveKind) !void {
    try c.set(root, "QuickFormat", @tagName(k));
    try c.set(root, "QuickExt", types.kind(k).ext);
}

/// Assoc.ApplyMenu: every menu entry in line with menu(): the archive verbs of the types MakePack is
/// registered for, the ProgID's own verbs, the file/folder items. Call after changing Menu or QuickKind.
/// `profiles` = settings.current().Profiles (C# read Settings.Current itself).
pub fn applyMenu(h: Hive, profiles: []const settings.Profile) !void {
    var s = Scratch.init();
    defer s.deinit();
    return applyMenuC(s.ctx(h), profiles);
}

fn fileKeys(comptime v: []const u8) [2][]const u8 {
    return .{ classes ++ "*\\shell\\MakePack." ++ v, classes ++ "Directory\\shell\\MakePack." ++ v };
}
const add_keys = fileKeys("Add");
const quick_keys = fileKeys("QuickAdd");

fn applyMenuC(c: Ctx, profiles: []const settings.Profile) !void {
    const m = menuC(c);
    const quick = quickKindC(c);
    try setQuickKindC(c, quick); // writes QuickExt for the DLL even when nobody ever picked a format
    for (all) |ext| {
        if (c.read(try c.cat(&.{ classes, ".", ext, "\\OpenWithProgids" }), prog_id) != null) try extVerbs(c, ext, m);
    }
    if (c.exists(classes ++ prog_id)) try progIdVerbs(c, m);
    for (add_keys) |k| try c.toggle(k, m.add, S.verbAddTo.get(), " a \"%1\"");
    const quick_caption = try S.fill(c.a, S.verbQuickAddFmt.get(), .{types.kind(quick).ext});
    for (quick_keys) |k| try c.toggle(k, m.quick_add, quick_caption, " a --quick \"%1\"");
    for (add_keys ++ quick_keys) |k| {
        if (c.exists(k)) try c.set(k, "MultiSelectModel", "Player"); // one call per item: MakePack merges them
    }
    try shellNew(c, m.new);
    try applyProfilesC(c, profiles);
}

// ---- the profiles' own items -------------------------------------------------------------------------

/// Assoc.ApplyProfiles: one item per profile marked InMenu (classic *\shell\MakePack.P01..., running
/// `a --profile "name"`) plus Software\MakePack\MenuProfiles\01.. for the DLL; rewritten whole every call;
/// writes nothing at all while no profile is in the menu. Call after profiles or menu() change.
pub fn applyProfiles(h: Hive, profiles: []const settings.Profile) !void {
    var s = Scratch.init();
    defer s.deinit();
    return applyProfilesC(s.ctx(h), profiles);
}

fn applyProfilesC(c: Ctx, profiles: []const settings.Profile) !void {
    try clearProfiles(c);
    if (!menuC(c).profiles) return;
    var n: usize = 0;
    for (profiles) |*p| {
        if (!p.InMenu or std.mem.findScalar(u8, p.Name, '"') != null) continue; // a quote would end the name in the command line
        n += 1;
        const id = try c.a.print("{d:0>2}", .{n}); // zero-padded: the DLL lists the subkeys in name order
        const template = if (p.Separate) S.verbProfileSeparateFmt else S.verbProfileFmt;
        const caption = try S.fill(c.a, template.get(), .{ p.ext(), p.Name });
        const args = try c.a.print(" a --profile \"{s}\" \"%1\"", .{p.Name});
        for ([_][]const u8{ classes ++ "*\\shell\\MakePack.P", classes ++ "Directory\\shell\\MakePack.P" }) |parent| {
            const key = try c.cat(&.{ parent, id });
            try c.verb(key, caption, args);
            try c.set(key, "MultiSelectModel", "Player"); // one call per item: MakePack merges them into one archive
        }
        const mp = try c.cat(&.{ menu_profiles, "\\", id });
        try c.set(mp, "Name", p.Name);
        try c.set(mp, "Ext", p.ext());
        try c.set(mp, "Separate", if (p.Separate) "1" else "0");
    }
}

fn clearProfiles(c: Ctx) !void {
    for ([_][]const u8{ classes ++ "*\\shell", classes ++ "Directory\\shell" }) |parent| {
        const k = reg.openKey(.hkcu, try c.path(parent), .{ .write = true }) catch continue;
        defer k.close();
        for (try k.subkeys(c.a)) |name| {
            if (!std.mem.startsWith(u8, name, "MakePack.P")) continue;
            reg.deleteKeyTree(.hkcu, try c.path(try c.cat(&.{ parent, "\\", name })), .default) catch |e| switch (e) {
                error.NotFound => {},
                else => return e,
            };
        }
    }
    c.delTree(menu_profiles);
}

fn extVerbs(c: Ctx, ext: []const u8, m: MenuItems) !void {
    const shell = try c.cat(&.{ classes, "SystemFileAssociations\\.", ext, "\\shell\\MakePack." });
    try c.toggle(try c.cat(&.{ shell, "Open" }), m.open, S.verbOpenWith.get(), " \"%1\"");
    try c.toggle(try c.cat(&.{ shell, "ExtractHere" }), m.extract_here, S.verbExtractHere.get(), " x \"%1\" --here");
    try c.toggle(try c.cat(&.{ shell, "ExtractTo" }), m.extract_to, S.verbExtractTo.get(), " x \"%1\" --sub");
}

fn progIdVerbs(c: Ctx, m: MenuItems) !void {
    const p = classes ++ prog_id ++ "\\shell\\MakePack.";
    try c.toggle(p ++ "ExtractHere", m.extract_here, S.verbExtractHere.get(), " x \"%1\" --here");
    try c.toggle(p ++ "ExtractTo", m.extract_to, S.verbExtractTo.get(), " x \"%1\" --sub");
}

// ---- Explorer's New > MakePack archive ---------------------------------------------------------------

/// Assoc.EmptySevenZip: signature, version 0.4, start-header CRC of 20 zero bytes, no next header.
pub const empty_seven_zip = [32]u8{
    0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x8D, 0x9B, 0xD5, 0x0F,
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
};

/// .7z\MakePack.Archive\ShellNew with the empty archive as its data. Explorer lists it as "MakePack archive"
/// only while .7z belongs to MakePack - under .7z\ShellNew it would be named after whoever owns .7z
/// (measured: a second entry named after the current .7z owner's type, next to its own), and someone else's ShellNew could sit there.
fn shellNew(c: Ctx, on: bool) !void {
    if (!on) return c.delTree(shell_new_key);
    const k = try reg.createKey(.hkcu, try c.path(shell_new_key ++ "\\ShellNew"), .default);
    defer k.close();
    try k.writeBinary("Data", &empty_seven_zip);
}

// ---- ProgID ------------------------------------------------------------------------------------------

/// Assoc.RegisterProgId: idempotent; always rewrites the exe path (the app may have been moved or reinstalled).
fn registerProgIdC(c: Ctx) !void {
    const p = classes ++ prog_id;
    const exe = try pw.exePath(c.a);
    try c.set(p, null, S.progIdDesc.get());
    try c.set(p ++ "\\DefaultIcon", null, try c.cat(&.{ "\"", exe, "\",0" }));
    try c.set(p ++ "\\shell\\open\\command", null, try c.cat(&.{ "\"", exe, "\" \"%1\"" }));
    try progIdVerbs(c, menuC(c));
    try c.set(caps, "ApplicationName", S.app);
    try c.set(caps, "ApplicationDescription", S.progIdDesc.get());
    try c.set(reg_apps, "MakePack", caps);
}

/// Assoc.Heal: repairs a half-removed registration - extensions still pointing at MakePack.Archive while the
/// ProgID itself, its Capabilities or its exe are gone (an --unregister that raced an install, or the app was
/// moved). Runs at every GUI start against the real HKCU, so it only READS when nothing is broken.
/// ponytail (from C#): a ProgID that merely lives somewhere else is another copy of MakePack (the installed
/// C# build, a portable or dev build), not damage: it is left alone, never hijacked.
pub fn heal(h: Hive) !void {
    var s = Scratch.init();
    defer s.deinit();
    const c = s.ctx(h);
    const exe = exeOf(c.a, c.read(classes ++ prog_id ++ "\\shell\\open\\command", null) orelse "");
    const app = c.read(reg_apps, "MakePack") orelse "";
    if (exe.len > 0 and pw.fileExists(exe) and app.len > 0) return;
    for (all) |ext| if (isOursC(c, ext)) return registerProgIdC(c);
}

// ---- who owns an extension ---------------------------------------------------------------------------

/// Assoc.Owner
pub const Owner = struct {
    /// HKCR\.ext default value (null = none). Allocated with the caller's allocator.
    prog_id: ?[]u8,
    /// The owner's open command points at an exe that is not there any more.
    dead: bool,
    /// Explorer has an explicit user choice for some other app...
    user_choice: bool,
    /// ...and that choice points at a ProgID/exe that is gone.
    choice_dead: bool,
};

pub fn owner(gpa: Allocator, h: Hive, ext: []const u8) !Owner {
    var s = Scratch.init();
    defer s.deinit();
    const o = try ownerC(s.ctx(h), ext);
    return .{
        .prog_id = if (o.prog_id) |p| try gpa.dupe(u8, p) else null,
        .dead = o.dead,
        .user_choice = o.user_choice,
        .choice_dead = o.choice_dead,
    };
}

fn ownerC(c: Ctx, ext: []const u8) !Owner {
    const id = c.readCr(try c.cat(&.{ ".", ext }), null); // HKCR = HKCU over HKLM, which is what Explorer sees
    const choice = c.read(try c.cat(&.{ file_exts, ".", ext, "\\UserChoice" }), "ProgId");
    const foreign = if (choice) |ch| ch.len > 0 and !eql(u8, ch, prog_id) else false;
    return .{
        .prog_id = id,
        .dead = if (id) |i| i.len > 0 and dead(c, i) else false,
        .user_choice = foreign,
        .choice_dead = foreign and dead(c, choice.?),
    };
}

/// A ProgID that no longer exists, or whose open command names an exe that is gone.
fn dead(c: Ctx, id: []const u8) bool {
    if (!c.existsCr(id)) return true;
    const cmd = c.readCr(c.cat(&.{ id, "\\shell\\open\\command" }) catch return false, null) orelse return false;
    if (std.mem.trim(u8, cmd, &std.ascii.whitespace).len == 0) return false; // DelegateExecute / packaged apps: not ours to judge
    const exe = exeOf(c.a, cmd);
    return exe.len > 0 and !pw.fileExists(exe);
}

/// The exe out of a shell command line: the first quoted token, else everything up to the first space.
fn exeOf(a: Allocator, command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    const cmd = reg.expandEnv(a, trimmed) catch trimmed;
    if (cmd.len > 0 and cmd[0] == '"') {
        if (std.mem.findScalarPos(u8, cmd, 1, '"')) |end| return cmd[1..end];
        return std.mem.trim(u8, cmd, "\"");
    }
    if (std.mem.findScalar(u8, cmd, ' ')) |space| if (space > 0) return cmd[0..space];
    return cmd;
}

/// Assoc.IsOurs: HKCR\.ext default == MakePack.Archive.
pub fn isOurs(h: Hive, ext: []const u8) bool {
    var s = Scratch.init();
    defer s.deinit();
    return isOursC(s.ctx(h), ext);
}

fn isOursC(c: Ctx, ext: []const u8) bool {
    const v = c.readCr(c.cat(&.{ ".", ext }) catch return false, null) orelse return false;
    return eql(u8, v, prog_id);
}

// ---- register / unregister one extension -------------------------------------------------------------

/// Assoc.Register's result (C# returned the bool and collected Blocked in a static list).
pub const Registered = struct {
    /// MakePack became the default handler.
    default: bool,
    /// Windows refused to clear its own UserChoice (S.blockedFmt lists these).
    blocked: bool,
};

/// Assoc.Register: verbs + Open-with always; the default handler when `force` or nobody usable owns it.
pub fn register(h: Hive, ext: []const u8, force: bool) !Registered {
    var s = Scratch.init();
    defer s.deinit();
    const c = s.ctx(h);
    const dotted = try c.cat(&.{ ".", ext });
    try registerProgIdC(c);
    try c.set(caps ++ "\\FileAssociations", dotted, prog_id);
    try c.set(try c.cat(&.{ classes, dotted, "\\OpenWithProgids" }), prog_id, "");
    try extVerbs(c, ext, menuC(c));

    // Unforced: only free (unowned, or owned by an uninstalled app) extensions, and .zip & co. only when dead.
    const o = try ownerC(c, ext);
    const unowned = if (o.prog_id) |p| p.len == 0 else true;
    if (!(force or o.dead or (unowned and isDefault(ext)))) return .{ .default = false, .blocked = false };

    const ext_key = try c.cat(&.{ classes, dotted });
    if (c.read(ext_key, null)) |prev| {
        if (prev.len > 0 and !eql(u8, prev, prog_id)) try c.set(prev_key, dotted, prev);
    }
    try c.set(ext_key, null, prog_id);

    // A live UserChoice overrides HKCR, so it has to go when forced; a dead one (app uninstalled) always goes.
    // Windows puts a deny-SetValue ACE on UserChoice; deleting the key needs only DELETE and usually works.
    var blocked = false;
    if (o.user_choice and (force or o.choice_dead)) blocked = !deleteUserChoice(c, dotted);
    return .{ .default = true, .blocked = blocked };
}

fn isDefault(ext: []const u8) bool {
    for (defaults) |d| if (std.ascii.eqlIgnoreCase(d, ext)) return true;
    return false;
}

/// OpenSubKey(FileExts\.ext, writable)?.DeleteSubKey("UserChoice", false); false = Windows refused.
fn deleteUserChoice(c: Ctx, dotted: []const u8) bool {
    const p = c.path(c.cat(&.{ file_exts, dotted }) catch return false) catch return false;
    const k = reg.openKey(.hkcu, p, .{ .write = true }) catch |e| return e == error.NotFound;
    defer k.close();
    const rc = kit.w.RegDeleteKeyW(k.h, reg.L("UserChoice"));
    return rc == 0 or rc == kit.w.ERROR_FILE_NOT_FOUND;
}

/// Assoc.Unregister: never touches someone else's default; restores the previous owner from Prev.
pub fn unregister(h: Hive, ext: []const u8) !void {
    var s = Scratch.init();
    defer s.deinit();
    return unregisterC(s.ctx(h), ext);
}

fn unregisterC(c: Ctx, ext: []const u8) !void {
    const dotted = try c.cat(&.{ ".", ext });
    const shell = try c.cat(&.{ classes, "SystemFileAssociations\\", dotted, "\\shell\\MakePack." });
    for ([_][]const u8{ "Open", "ExtractHere", "ExtractTo" }) |v| c.delTree(try c.cat(&.{ shell, v }));
    c.delValue(try c.cat(&.{ classes, dotted, "\\OpenWithProgids" }), prog_id);
    c.delValue(caps ++ "\\FileAssociations", dotted);

    const k = reg.openKey(.hkcu, try c.path(try c.cat(&.{ classes, dotted })), .{ .write = true }) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    defer k.close();
    const current = k.readString(c.a, null) catch return;
    if (!eql(u8, current, prog_id)) return; // never touch someone else's default
    if (c.read(prev_key, dotted)) |prev| try k.writeString(null, prev) else k.deleteValue(null) catch {};
    c.delValue(prev_key, dotted);
}

// ---- the items on every file and folder (--addmenu, the installer's "context menu" task) --------------

/// Assoc.SetAddMenu (--addmenu on|off).
pub fn setAddMenu(h: Hive, on: bool, profiles: []const settings.Profile) !void {
    var s = Scratch.init();
    defer s.deinit();
    const c = s.ctx(h);
    const m: u32 = @bitCast(menuC(c));
    const f: u32 = @bitCast(MenuItems.files);
    try setMenuC(c, @bitCast(if (on) m | f else m & ~f));
    try applyMenuC(c, profiles);
}

/// Assoc.UnregisterAll (--unregister without a list; the uninstaller).
pub fn unregisterAll(h: Hive) !void {
    var s = Scratch.init();
    defer s.deinit();
    const c = s.ctx(h);
    for (all) |ext| try unregisterC(c, ext);
    for (add_keys ++ quick_keys) |k| c.delTree(k);
    try shellNew(c, false);
    try clearProfiles(c);
    c.delTree(classes ++ prog_id);
    c.delTree(root);
    c.delValue(reg_apps, "MakePack");
}

/// Assoc.Notify: SHChangeNotify(SHCNE_ASSOCCHANGED) once after a batch of changes, never per extension.
pub fn notify() void {
    kit.w.SHChangeNotify(@intCast(kit.w.SHCNE_ASSOCCHANGED), 0, null, null);
}

test "contract compiles" {
    try std.testing.expectEqual(@as(u32, 127), @as(u32, @bitCast(MenuItems.all_items)));
    try std.testing.expectEqual(@as(u32, 8 | 16 | 32 | 64), @as(u32, @bitCast(MenuItems.files)));
    @import("../testutil.zig").refAllDeep(@This(), 2);
}

test "exeOf: quoted, unquoted, %vars%" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("C:\\Program Files\\X\\x.exe", exeOf(a, "  \"C:\\Program Files\\X\\x.exe\" \"%1\""));
    try std.testing.expectEqualStrings("C:\\x.exe", exeOf(a, "C:\\x.exe %1"));
    try std.testing.expectEqualStrings("C:\\x.exe", exeOf(a, "\"C:\\x.exe"));
    const win = (try reg.getEnv(a, "SystemRoot")).?;
    try std.testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ win, "\\notepad.exe" }), exeOf(a, "%SystemRoot%\\notepad.exe %1"));
    try std.testing.expectEqualStrings("", exeOf(a, ""));
}
