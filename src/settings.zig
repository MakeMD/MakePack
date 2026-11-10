//! The user's options (Settings.cs), kept in %APPDATA%\MakePack\settings.json (MAKEPACK_SETTINGS overrides
//! the path for tests). A missing or broken file means defaults; the next save simply writes a good one.
//!
//! The structs mirror the JSON written by the C# build: field names ARE the JSON keys (PascalCase) and the
//! enums are spelled like their C# members, so std.json reads and writes the same schema with no mapping
//! layer. Unknown keys (the C# build also wrote each profile's computed "Ext") are ignored.
//! ponytail: enum names match case-sensitively; System.Text.Json also accepted "zip" for "Zip" - a
//! hand-edited lowercase name falls back to defaults here.
const std = @import("std");
const kit = @import("kit");
const types = @import("core/types.zig");
const strings = @import("strings.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A folder on disk, or an archive (and the folder inside it, "" = its root).
pub const Favorite = struct {
    Name: []const u8 = "",
    Path: []const u8 = "",
    Inner: ?[]const u8 = null,
};

/// A named set of New-archive options (compression profiles). Never a password: the encryption
/// flags only take effect once one is typed in the dialog.
pub const Profile = struct {
    Name: []const u8 = "",
    /// Applied whenever the New archive dialog opens.
    IsDefault: bool = false,
    /// Has its own "Add to name (profile)" item in Explorer's menu, which runs `a --profile` (no dialog).
    InMenu: bool = false,
    Format: types.ArchiveKind = .SevenZip,
    Level: types.CompressionLevel = .Normal,
    /// TRAP kept from C#: CompressionMethod's zero value is Copy (no compression); the default is .Default.
    Method: types.CompressionMethod = .Default,
    Dictionary: i64 = 0,
    Solid: ?[]const u8 = null,
    Threads: i32 = 0,
    Filter: ?[]const u8 = null,
    /// As typed in the Volumes box ("700 MB (CD)"); empty = one file.
    Volumes: []const u8 = "",
    TestAfter: bool = false,
    DeleteSources: bool = false,
    Separate: bool = false,
    Sfx: bool = false,
    EncryptNames: bool = false,
    ZipCrypto: bool = false,

    /// Profile.Ext
    pub fn ext(p: *const Profile) []const u8 {
        return if (p.Sfx) ".exe" else types.kind(p.Format).ext;
    }

    /// What a run without the dialog uses (CLI, Explorer menu): no password, so no encryption either.
    pub fn toOptions(p: *const Profile) types.CompressOptions {
        return .{
            .level = p.Level,
            .method = p.Method,
            .dictionary = p.Dictionary,
            .solid = p.Solid,
            .threads = p.Threads,
            .filter = p.Filter,
            .volume_size = types.parseSize(p.Volumes) orelse 0,
            .test_after = p.TestAfter,
            .delete_sources = p.DeleteSources,
            .sfx = p.Sfx,
        };
    }
};

pub const Settings = struct {
    /// Last format and level picked in the New archive dialog.
    Format: types.ArchiveKind = .SevenZip,
    Level: types.CompressionLevel = .Normal,
    /// "Test the archive when done". Deleting the sources is never remembered.
    TestAfter: bool = false,
    /// The Advanced block of that dialog; same meaning as the CompressOptions fields of the same name.
    ShowAdvanced: bool = false,
    Method: types.CompressionMethod = .Default,
    Dictionary: i64 = 0,
    Solid: ?[]const u8 = null,
    Threads: i32 = 0,
    Filter: ?[]const u8 = null,
    /// The extract dialog's last choices.
    ExtractOverwrite: types.OverwriteMode = .Ask,
    ExtractNoPaths: bool = false,
    ExtractUpdate: types.UpdateMode = .Replace,
    ExtractKeepBroken: bool = false,
    ExtractDeleteAfter: types.DeleteAfter = .Never,
    /// Which extracted files inherit the archive's "from the Internet" mark.
    Motw: types.MotwPolicy = .Risky,
    /// Where new archives go. null = next to the files being packed.
    ArchiveFolder: ?[]const u8 = null,
    /// The main window: x, y, width, height; where it was, how the list looked, which folder it showed last.
    Window: ?[]const i32 = null,
    Maximized: bool = false,
    Tree: bool = false,
    ListMode: bool = false,
    FlatView: bool = false,
    LastFolder: ?[]const u8 = null,
    /// Favorites menu, in menu order; the first ten answer Ctrl+1...0.
    Favorites: []const Favorite = &.{},
    /// Named option sets for the New archive dialog and `a --profile`; at most one IsDefault.
    Profiles: []const Profile = &.{},

    /// Settings.FindProfile: names match like .NET's OrdinalIgnoreCase ("backup" finds "Backup", Cyrillic too).
    pub fn findProfile(s: *const Settings, profile_name: []const u8) ?*const Profile {
        for (s.Profiles) |*p| if (types.eqlIgnoreCase(p.Name, profile_name)) return p;
        return null;
    }
};

// ---- load / save ------------------------------------------------------------------------------------

/// Settings plus the arena that owns their strings and lists. Edits assign arena-allocated data
/// (`allocator()`); ponytail: replaced values stay in the arena until deinit - a session's worth of edits.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    v: Settings = .{},

    pub fn allocator(l: *Loaded) Allocator {
        return l.arena.allocator();
    }

    pub fn deinit(l: *Loaded) void {
        l.arena.deinit();
    }
};

/// Settings.Load: missing, unreadable or hand-broken = defaults (never an error).
pub fn load(gpa: Allocator, io: Io, path: []const u8) Loaded {
    var l: Loaded = .{ .arena = .init(gpa) };
    l.v = parse(l.arena.allocator(), io, path) catch .{};
    return l;
}

fn parse(a: Allocator, io: Io, path: []const u8) !Settings {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20));
    const text = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw; // File.ReadAllText drops a BOM
    return std.json.parseFromSliceLeaky(Settings, a, text, .{
        .ignore_unknown_fields = true, // "Ext", and keys of newer builds
        .duplicate_field_behavior = .use_last, // System.Text.Json: the last one wins
        .allocate = .alloc_always,
    });
}

/// Settings.Save. Best effort: losing a remembered option is not worth an error box.
pub fn save(s: *const Settings, gpa: Allocator, io: Io, path: []const u8) void {
    saveOrFail(s, gpa, io, path) catch {}; // read-only profile, full disk...
}

/// `save` that reports why it failed (tests). Never stores a password: Settings has no field for one.
pub fn saveOrFail(s: *const Settings, gpa: Allocator, io: Io, path: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, s.*, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    // Write-then-move, so a crash mid-write never leaves half a file. ponytail: std's atomic file (random
    // temp name + rename) instead of C#'s fixed "settings.json.tmp".
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = atomic.file.writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.flush();
    try atomic.replace(io);
}

/// Settings.DefaultPath: MAKEPACK_SETTINGS (tests: selftest, GUI smoke) or %APPDATA%\MakePack\settings.json.
pub fn defaultPath(gpa: Allocator) ![]u8 {
    if (try kit.win.getEnv(gpa, "MAKEPACK_SETTINGS")) |p| {
        if (p.len > 0) return p;
        gpa.free(p);
    }
    const appdata = try kit.win.knownFolder(gpa, &kit.w.FOLDERID_RoamingAppData);
    defer gpa.free(appdata);
    return std.mem.concat(gpa, u8, &.{ appdata, "\\", strings.app, "\\settings.json" });
}

// ---- Settings.Current -------------------------------------------------------------------------------
// This process's copy. One process per session (single.zig), so no cross-process merging.
// C# Update(change) = mutate `current()` (strings/lists from `arena()`), then `commit()`.

var cur: ?struct { gpa: Allocator, io: Io, l: Loaded } = null;

/// Loads DefaultPath. Call once at startup (main); `deinit` at exit.
pub fn init(gpa: Allocator, io: Io) void {
    cur = .{ .gpa = gpa, .io = io, .l = .{ .arena = .init(gpa) } };
    reload();
}

pub fn deinit() void {
    if (cur) |*c| c.l.deinit();
    cur = null;
}

/// Settings.Current
pub fn current() *Settings {
    return &cur.?.l.v;
}

/// Allocator for strings and lists assigned into current().
pub fn arena() Allocator {
    return cur.?.l.allocator();
}

/// The save half of Settings.Update: writes current() to DefaultPath.
pub fn commit() void {
    const c = &cur.?;
    const path = defaultPath(c.gpa) catch return;
    defer c.gpa.free(path);
    save(&c.l.v, c.gpa, c.io, path);
}

/// Settings.Reset: defaults, saved.
pub fn reset() void {
    current().* = .{};
    commit();
}

/// Settings.Reload: re-reads DefaultPath (after a test switched MAKEPACK_SETTINGS).
pub fn reload() void {
    const c = &cur.?;
    const path = defaultPath(c.gpa) catch null;
    defer if (path) |p| c.gpa.free(p);
    c.l.deinit();
    c.l = if (path) |p| load(c.gpa, c.io, p) else .{ .arena = .init(c.gpa) };
}

// ---- tests ------------------------------------------------------------------------------------------

const tt = std.testing;
const testutil = @import("testutil.zig");

/// What the C# build (System.Text.Json, WriteIndented, JsonStringEnumConverter) writes: every property in
/// declaration order, nulls included, non-ASCII escaped as \uXXXX, and the computed Profile.Ext at the end.
const csharp_json =
    \\{
    \\  "Format": "TarXz",
    \\  "Level": "Ultra",
    \\  "TestAfter": true,
    \\  "ShowAdvanced": true,
    \\  "Method": "Lzma",
    \\  "Dictionary": 67108864,
    \\  "Solid": "256m",
    \\  "Threads": 4,
    \\  "Filter": "BCJ2",
    \\  "ExtractOverwrite": "Rename",
    \\  "ExtractNoPaths": true,
    \\  "ExtractUpdate": "Existing",
    \\  "ExtractKeepBroken": true,
    \\  "ExtractDeleteAfter": "Recycle",
    \\  "Motw": "All",
    \\  "ArchiveFolder": "D:\\\u0410\u0440\u0445\u0456\u0432\u0438",
    \\  "Window": [
    \\    -10,
    \\    20,
    \\    1200,
    \\    800
    \\  ],
    \\  "Maximized": true,
    \\  "Tree": true,
    \\  "ListMode": true,
    \\  "FlatView": true,
    \\  "LastFolder": "C:\\Users\\x",
    \\  "Favorites": [
    \\    {
    \\      "Name": "Docs",
    \\      "Path": "C:\\Docs",
    \\      "Inner": null
    \\    },
    \\    {
    \\      "Name": "\u0410\u0440\u0445\u0456\u0432",
    \\      "Path": "C:\\a.7z",
    \\      "Inner": "sub/dir"
    \\    }
    \\  ],
    \\  "Profiles": [
    \\    {
    \\      "Name": "Backup",
    \\      "IsDefault": true,
    \\      "InMenu": true,
    \\      "Format": "Zip",
    \\      "Level": "High",
    \\      "Method": "Lzma",
    \\      "Dictionary": 4194304,
    \\      "Solid": null,
    \\      "Threads": 2,
    \\      "Filter": null,
    \\      "Volumes": "700 MB (CD)",
    \\      "TestAfter": true,
    \\      "DeleteSources": true,
    \\      "Separate": true,
    \\      "Sfx": false,
    \\      "EncryptNames": true,
    \\      "ZipCrypto": true,
    \\      "Ext": ".zip"
    \\    },
    \\    {
    \\      "Name": "\u0411\u0435\u043A\u0430\u043F",
    \\      "IsDefault": false,
    \\      "InMenu": false,
    \\      "Format": "SevenZip",
    \\      "Level": "None",
    \\      "Method": "Copy",
    \\      "Dictionary": 0,
    \\      "Solid": "off",
    \\      "Threads": 0,
    \\      "Filter": "ARM64",
    \\      "Volumes": "",
    \\      "TestAfter": false,
    \\      "DeleteSources": false,
    \\      "Separate": false,
    \\      "Sfx": true,
    \\      "EncryptNames": false,
    \\      "ZipCrypto": false,
    \\      "Ext": ".exe"
    \\    },
    \\    {
    \\      "Name": "Fresh"
    \\    }
    \\  ]
    \\}
;

fn expectCSharpFixture(s: *const Settings) !void {
    try tt.expectEqual(types.ArchiveKind.TarXz, s.Format);
    try tt.expectEqual(types.CompressionLevel.Ultra, s.Level);
    try tt.expect(s.TestAfter and s.ShowAdvanced);
    try tt.expectEqual(types.CompressionMethod.Lzma, s.Method);
    try tt.expectEqual(@as(i64, 64 << 20), s.Dictionary);
    try tt.expectEqualStrings("256m", s.Solid.?);
    try tt.expectEqual(@as(i32, 4), s.Threads);
    try tt.expectEqualStrings("BCJ2", s.Filter.?);
    try tt.expectEqual(types.OverwriteMode.Rename, s.ExtractOverwrite);
    try tt.expect(s.ExtractNoPaths and s.ExtractKeepBroken);
    try tt.expectEqual(types.UpdateMode.Existing, s.ExtractUpdate);
    try tt.expectEqual(types.DeleteAfter.Recycle, s.ExtractDeleteAfter);
    try tt.expectEqual(types.MotwPolicy.All, s.Motw);
    try tt.expectEqualStrings("D:\\Архіви", s.ArchiveFolder.?);
    try tt.expectEqualSlices(i32, &.{ -10, 20, 1200, 800 }, s.Window.?);
    try tt.expect(s.Maximized and s.Tree and s.ListMode and s.FlatView);
    try tt.expectEqualStrings("C:\\Users\\x", s.LastFolder.?);

    try tt.expectEqual(@as(usize, 2), s.Favorites.len);
    try tt.expectEqualStrings("Docs", s.Favorites[0].Name);
    try tt.expectEqualStrings("C:\\Docs", s.Favorites[0].Path);
    try tt.expect(s.Favorites[0].Inner == null);
    try tt.expectEqualStrings("Архів", s.Favorites[1].Name);
    try tt.expectEqualStrings("sub/dir", s.Favorites[1].Inner.?);

    try tt.expectEqual(@as(usize, 3), s.Profiles.len);
    const b = s.findProfile("backup").?; // names match case-insensitively
    try tt.expect(b.IsDefault and b.InMenu and b.TestAfter and b.DeleteSources and b.Separate and b.EncryptNames and b.ZipCrypto and !b.Sfx);
    try tt.expectEqual(types.ArchiveKind.Zip, b.Format);
    try tt.expectEqual(types.CompressionLevel.High, b.Level);
    try tt.expectEqual(types.CompressionMethod.Lzma, b.Method);
    try tt.expectEqual(@as(i64, 4 << 20), b.Dictionary);
    try tt.expect(b.Solid == null and b.Filter == null);
    try tt.expectEqual(@as(i32, 2), b.Threads);
    try tt.expectEqualStrings("700 MB (CD)", b.Volumes);
    try tt.expectEqualStrings(".zip", b.ext());

    const u = s.findProfile("бЕКАП").?; // OrdinalIgnoreCase folds Cyrillic too
    try tt.expectEqual(types.CompressionMethod.Copy, u.Method); // an explicit Copy stays Copy
    try tt.expectEqual(types.CompressionLevel.None, u.Level);
    try tt.expect(u.Sfx and !u.IsDefault);
    try tt.expectEqualStrings("off", u.Solid.?);
    try tt.expectEqualStrings("ARM64", u.Filter.?);
    try tt.expectEqualStrings(".exe", u.ext());

    const f = s.findProfile("FRESH").?; // missing keys = the C# initializers
    try tt.expectEqual(types.CompressionMethod.Default, f.Method); // not Copy (= no compression)
    try tt.expectEqual(types.ArchiveKind.SevenZip, f.Format);
    try tt.expectEqual(types.CompressionLevel.Normal, f.Level);
    try tt.expectEqualStrings("", f.Volumes);
    try tt.expect(s.findProfile("nope") == null);
}

test "defaults are the C# initializers" {
    const s: Settings = .{};
    try tt.expectEqual(types.ArchiveKind.SevenZip, s.Format);
    try tt.expectEqual(types.CompressionLevel.Normal, s.Level);
    try tt.expectEqual(types.CompressionMethod.Default, s.Method);
    try tt.expectEqual(types.OverwriteMode.Ask, s.ExtractOverwrite);
    try tt.expectEqual(types.UpdateMode.Replace, s.ExtractUpdate);
    try tt.expectEqual(types.DeleteAfter.Never, s.ExtractDeleteAfter);
    try tt.expectEqual(types.MotwPolicy.Risky, s.Motw);
    try tt.expect(s.ArchiveFolder == null and s.Window == null and s.Favorites.len == 0 and s.Profiles.len == 0);
    const p: Profile = .{ .Name = "Fresh" };
    try tt.expectEqual(types.CompressionMethod.Default, p.Method); // default(enum) would be Copy
    try tt.expectEqualStrings(".7z", p.ext());
}

test "reads the C# format, writes it back, reads the same" {
    const gpa = tt.allocator;
    const io = tt.io;
    var tmp = try testutil.TempDir.init(gpa, io);
    defer tmp.deinit();
    const path = try tmp.join("cfg\\settings.json"); // folder does not exist yet: save creates it
    defer gpa.free(path);

    var missing = load(gpa, io, path);
    defer missing.deinit();
    try tt.expectEqualDeep(Settings{}, missing.v);

    const fixture = try tmp.join("csharp.json");
    defer gpa.free(fixture);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fixture, .data = csharp_json });
    var cs = load(gpa, io, fixture);
    defer cs.deinit();
    try expectCSharpFixture(&cs.v);

    try saveOrFail(&cs.v, gpa, io, path);
    var back = load(gpa, io, path);
    defer back.deinit();
    try expectCSharpFixture(&back.v);
    try tt.expectEqualDeep(cs.v, back.v);

    const written = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(written);
    try tt.expect(std.ascii.findIgnoreCase(written, "password") == null); // a profile never carries one
    try tt.expect(std.mem.find(u8, written, "\"Format\": \"TarXz\"") != null); // C# spelling, indented
    try tt.expect(std.mem.find(u8, written, "\"Method\": \"Default\"") != null); // Fresh's default method

    // A second save replaces the file and leaves nothing else behind (no temp file).
    try saveOrFail(&Settings{ .Format = .Zip }, gpa, io, path);
    var again = load(gpa, io, path);
    defer again.deinit();
    try tt.expectEqual(types.ArchiveKind.Zip, again.v.Format);
    const cfg_dir = try tmp.join("cfg");
    defer gpa.free(cfg_dir);
    var dir = try Io.Dir.cwd().openDir(io, cfg_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| : (n += 1) try tt.expectEqualStrings("settings.json", e.name);
    try tt.expectEqual(@as(usize, 1), n);
}

test "a broken file means defaults" {
    const gpa = tt.allocator;
    const io = tt.io;
    var tmp = try testutil.TempDir.init(gpa, io);
    defer tmp.deinit();
    const path = try tmp.join("settings.json");
    defer gpa.free(path);
    // The junk list of the C# selftest, plus a wrong type, a null for a bool and a trailing comma.
    for ([_][]const u8{ "{broken", "", "null", "{\"Format\":\"NoSuchKind\"}", "[1,2]", "{\"Threads\":\"many\"}", "{\"TestAfter\":null}", "{\"Tree\":true,}" }) |junk| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = junk });
        var d = load(gpa, io, path);
        defer d.deinit();
        try tt.expectEqualDeep(Settings{}, d.v);
    }
    // Things System.Text.Json accepted load here too: a BOM, an enum as its number, unknown keys, duplicates.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "\xEF\xBB\xBF{\"Format\":1,\"Level\":5,\"NewKey\":{\"a\":[1]},\"Tree\":false,\"Tree\":true}" });
    var ok = load(gpa, io, path);
    defer ok.deinit();
    try tt.expectEqual(types.ArchiveKind.Zip, ok.v.Format);
    try tt.expectEqual(types.CompressionLevel.Ultra, ok.v.Level);
    try tt.expect(ok.v.Tree);
}

test "profile options without the dialog" {
    const b: Profile = .{
        .Name = "Backup",
        .IsDefault = true,
        .Format = .Zip,
        .Level = .High,
        .Method = .Lzma,
        .Dictionary = 4 << 20,
        .Threads = 2,
        .Volumes = "700 MB (CD)",
        .TestAfter = true,
        .DeleteSources = true,
        .Separate = true,
        .ZipCrypto = true,
        .EncryptNames = true,
    };
    const o = b.toOptions();
    try tt.expect(o.password == null and !o.zip_crypto and !o.encrypt_headers); // no password, no encryption
    try tt.expect(o.volume_size == 700 << 20 and o.dictionary == 4 << 20 and o.test_after and o.delete_sources);
    try tt.expect(o.level == .High and o.method == .Lzma and o.threads == 2 and !o.sfx);
    const setup: Profile = .{ .Name = "Setup", .Sfx = true, .Solid = "off", .Filter = "BCJ2" };
    try tt.expectEqualStrings(".exe", setup.ext());
    try tt.expect(setup.toOptions().sfx and std.mem.eql(u8, setup.toOptions().solid.?, "off"));
    try tt.expectEqual(@as(i64, 0), (Profile{ .Volumes = "nonsense" }).toOptions().volume_size); // ParseSize ?? 0
}

test "Settings.Current follows MAKEPACK_SETTINGS" {
    const gpa = tt.allocator;
    const io = tt.io;
    var tmp = try testutil.TempDir.init(gpa, io);
    defer tmp.deinit();
    const path = try tmp.join("current\\settings.json");
    defer gpa.free(path);
    const before = try kit.win.getEnv(gpa, "MAKEPACK_SETTINGS");
    defer if (before) |b| gpa.free(b);
    try testutil.setEnv("MAKEPACK_SETTINGS", path);
    defer testutil.setEnv("MAKEPACK_SETTINGS", before) catch {};

    const dp = try defaultPath(gpa);
    defer gpa.free(dp);
    try tt.expectEqualStrings(path, dp);

    init(gpa, io);
    defer deinit();
    try tt.expectEqualDeep(Settings{}, current().*);
    current().ArchiveFolder = try arena().dupe(u8, "E:\\Нове");
    current().Profiles = try arena().dupe(Profile, &.{.{ .Name = "Q", .Format = .TarGz }});
    commit();
    reload();
    try tt.expectEqualStrings("E:\\Нове", current().ArchiveFolder.?);
    try tt.expectEqual(types.ArchiveKind.TarGz, current().findProfile("q").?.Format);
    reset();
    reload();
    try tt.expectEqualDeep(Settings{}, current().*);
}

test "default path is under APPDATA when MAKEPACK_SETTINGS is empty" {
    const gpa = tt.allocator;
    const before = try kit.win.getEnv(gpa, "MAKEPACK_SETTINGS");
    defer if (before) |b| gpa.free(b);
    try testutil.setEnv("MAKEPACK_SETTINGS", "");
    defer testutil.setEnv("MAKEPACK_SETTINGS", before) catch {};
    const p = try defaultPath(gpa);
    defer gpa.free(p);
    try tt.expect(std.mem.endsWith(u8, p, "\\MakePack\\settings.json") and Io.Dir.path.isAbsolute(p));
}
