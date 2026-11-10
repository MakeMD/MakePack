//! MakePackShell.dll - the "MakePack" submenu of the Windows 11 (top-level) Explorer context menu.
//! Port of legacy/shell/MakePackShell.cpp. One IExplorerCommand class (root + subcommands), registered by the sparse
//! package in shell/package. The classic registry verbs (src/platform/assoc.zig) stay as they are for Windows 10 and
//! "Show more options". Every action just starts MakePack.exe from this DLL's folder with the same CLI the classic
//! verbs use. Reads HKCU\Software\MakePack MenuItems (DWORD), QuickExt and MenuProfiles\NN {Name, Ext, Separate}
//! fresh on every call (written by src/platform/assoc.zig). shell/test/harness.cpp drives it like Explorer.
//! This module cannot import src/: the lists and strings below are its own copies, as in the C++.
const std = @import("std");
const w = @import("kit").w;

const Allocator = std.mem.Allocator;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const HRESULT = w.HRESULT;
const S_OK: HRESULT = 0;

/// The one CLSID of the MakePack Explorer command. Also in shell/package/AppxManifest.xml (Verb + com:Class) and
/// shell/test/harness.cpp - keep in sync.
pub const clsid_command = guid("{21DB9173-64FA-4183-A08E-E073FEBB7B8D}");

// ---- what is selected ---------------------------------------------------------------------------

/// Same list as archive_exts (Assoc.All) in src/core/types.zig - keep in sync.
const archive_exts = [_][]const u8{
    "7z",   "zip",  "zipx", "jar",  "rar", "tar", "gz",  "tgz", "bz2", "tbz2", "tbz", "xz",
    "txz",  "lzma", "z",    "taz",  "cab", "iso", "wim", "swm", "esd", "arj",  "lzh", "lha",
    "cpio", "rpm",  "deb",  "udeb", "ar",  "xar", "dmg", "vhd", "001", "ova",
};
/// Same as Engine.TarballExts - keep in sync.
const tarball_exts = [_][]const u8{ ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz" };

/// _wcsicmp against an ASCII pattern (only A-Z fold, like the C locale).
fn eqlIgnoreCase(a: []const u16, ascii: []const u8) bool {
    if (a.len != ascii.len) return false;
    for (a, ascii) |c, p| if (c > 0x7f or std.ascii.toLower(@intCast(c)) != std.ascii.toLower(p)) return false;
    return true;
}

/// PathFindFileNameW: after the last '\', '/' or ':' that is followed by a name ("C:\a\" -> "a\", "C:\" -> "C:\").
fn fileName(p: []const u16) []const u16 {
    var start: usize = 0;
    for (p, 0..) |c, i| {
        if ((c == '\\' or c == '/' or c == ':') and i + 1 < p.len and p[i + 1] != '\\' and p[i + 1] != '/') start = i + 1;
    }
    return p[start..];
}

/// PathFindExtensionW: from the last '.' that no '\' or ' ' follows, else "".
fn extension(p: []const u16) []const u16 {
    var dot: ?usize = null;
    for (p, 0..) |c, i| switch (c) {
        '\\', ' ' => dot = null,
        '.' => dot = i,
        else => {},
    };
    return p[dot orelse p.len ..];
}

// ponytail: extension only, no disk access - a folder named "x.zip" counts as an archive, like the classic verbs.
fn isArchive(path: []const u16) bool {
    const ext = extension(path);
    if (ext.len == 0) return false;
    for (archive_exts) |e| if (eqlIgnoreCase(ext[1..], e)) return true;
    return false;
}

/// Engine.BaseName: "a.tar.gz" -> "a", "b.zip" -> "b".
fn baseName(path: []const u16) []const u16 {
    const name = fileName(path);
    for (tarball_exts) |e| {
        if (name.len >= e.len and eqlIgnoreCase(name[name.len - e.len ..], e)) return name[0 .. name.len - e.len];
    }
    return name[0 .. std.mem.findScalarLast(u16, name, '.') orelse name.len];
}

/// Engine.DefaultArchivePath: one item -> its name (a file loses its last extension), several -> their folder's name.
fn archiveBase(paths: []const [:0]const u16) []const u16 {
    var name: []const u16 = &.{};
    if (paths.len == 1) {
        name = fileName(paths[0]);
        const attr = w.GetFileAttributesW(paths[0].ptr);
        if (attr == w.INVALID_FILE_ATTRIBUTES or attr & w.FILE_ATTRIBUTE_DIRECTORY == 0) {
            if (std.mem.findScalarLast(u16, name, '.')) |dot| {
                if (dot > 0) name = name[0..dot];
            }
        }
    } else if (paths.len > 1) {
        const p = paths[0];
        name = fileName(p[0 .. std.mem.findScalarLast(u16, p, '\\') orelse p.len]);
        if (std.mem.findScalar(u16, name, ':') != null) name = &.{}; // the items sit in a drive root
    }
    return if (name.len == 0) L("MakePack") else name;
}

const Selection = struct {
    count: w.DWORD = 0, // everything selected
    paths: []const [:0]const u16 = &.{}, // ...of which these have a file-system path

    fn allArchives(s: Selection) bool {
        if (s.count == 0 or s.paths.len != s.count) return false;
        for (s.paths) |p| if (!isArchive(p)) return false;
        return true;
    }
};

// ponytail: re-read on every GetTitle/GetState call; cache per IShellItemArray if huge selections feel slow.
fn read(a: Allocator, items: [*c]w.IShellItemArray) Allocator.Error!Selection {
    var s: Selection = .{};
    if (items == null or items.*.lpVtbl.*.GetCount.?(items, &s.count) < 0) return .{};
    var paths: std.ArrayList([:0]const u16) = .empty;
    for (0..s.count) |i| {
        var item: [*c]w.IShellItem = null;
        if (items.*.lpVtbl.*.GetItemAt.?(items, @intCast(i), &item) < 0) continue;
        defer _ = item.*.lpVtbl.*.Release.?(item);
        var path: w.LPWSTR = null;
        if (item.*.lpVtbl.*.GetDisplayName.?(item, w.SIGDN_FILESYSPATH, &path) < 0) continue;
        defer w.CoTaskMemFree(path);
        try paths.append(a, try a.dupeSentinel(u16, std.mem.span(path), 0));
    }
    s.paths = paths.items;
    return s;
}

// ---- the user's choices, written by MakePack (assoc.zig menu / quickKind / applyProfiles) ----------

const root_key = L("Software\\MakePack");

/// MenuItems flags - same values as the C# enum. No value at all = everything on.
const Flag = struct {
    const open = 1;
    const here = 2;
    const to = 4;
    const add = 8;
    const quick = 16;
    const profiles = 64;
};

/// HKEY_CURRENT_USER = (HKEY)(LONG)0x80000001, sign-extended (RegOverridePredefKey rejects the zero-extended value).
/// An odd pointer value, so it is built at runtime (MakeKit notes K4).
fn hkcu() w.HKEY {
    var v: usize = 0xFFFFFFFF_80000001;
    _ = &v;
    @setRuntimeSafety(false);
    return @ptrFromInt(v);
}

fn menuFlags() u32 {
    var v: w.DWORD = 0;
    var size: w.DWORD = @sizeOf(w.DWORD);
    return if (w.RegGetValueW(hkcu(), root_key, L("MenuItems"), w.RRF_RT_REG_DWORD, null, &v, &size) == 0) v else 0xFFFFFFFF;
}

fn quickExt(buf: *[32]u16) []const u16 {
    var size: w.DWORD = @sizeOf([32]u16);
    if (w.RegGetValueW(hkcu(), root_key, L("QuickExt"), w.RRF_RT_REG_SZ, null, buf, &size) != 0) return L(".7z");
    return std.mem.sliceTo(buf, 0);
}

/// A profile marked "in menu": HKCU\Software\MakePack\MenuProfiles\01, 02... (assoc.applyProfiles writes them).
const MenuProfile = struct { name: []const u16, ext: []const u16, separate: bool };

fn menuProfiles(a: Allocator) Allocator.Error![]const MenuProfile {
    var k: w.HKEY = null;
    if (w.RegOpenKeyExW(hkcu(), L("Software\\MakePack\\MenuProfiles"), 0, w.KEY_READ, &k) != 0) return &.{};
    defer _ = w.RegCloseKey(k);
    var list: std.ArrayList(MenuProfile) = .empty;
    var sub: [32]u16 = undefined;
    var i: w.DWORD = 0;
    while (true) : (i += 1) {
        var n: w.DWORD = sub.len;
        if (w.RegEnumKeyExW(k, i, &sub, &n, null, null, null, null) != 0) break;
        const p: MenuProfile = .{
            .name = try regText(a, k, &sub, L("Name")),
            .ext = try regText(a, k, &sub, L("Ext")),
            .separate = std.mem.eql(u16, try regText(a, k, &sub, L("Separate")), L("1")),
        };
        if (p.name.len != 0) try list.append(a, p);
    }
    return list.items; // subkeys are zero-padded, so name order is their order
}

fn regText(a: Allocator, k: w.HKEY, sub: [*c]const u16, value: [*:0]const u16) Allocator.Error![]const u16 {
    var buf: [512]u16 = undefined;
    var size: w.DWORD = @sizeOf([512]u16);
    if (w.RegGetValueW(k, sub, value, w.RRF_RT_REG_SZ, null, &buf, &size) != 0) return &.{};
    return a.dupe(u16, std.mem.sliceTo(&buf, 0));
}

// ---- the commands -------------------------------------------------------------------------------

const Kind = enum { root, open, here, to, add, quick, profile };
const subs = [_]Kind{ .open, .here, .to, .add, .quick }; // then one .profile command per MenuProfiles entry

/// `profile` = the MenuProfiles index of a .profile command, unused for every other kind.
fn visible(a: Allocator, k: Kind, s: Selection, profile: w.ULONG) Allocator.Error!bool {
    const on = menuFlags();
    return switch (k) {
        .open => on & Flag.open != 0 and s.count == 1 and s.allArchives(),
        .here => on & Flag.here != 0 and s.allArchives(),
        .to => on & Flag.to != 0 and s.allArchives(),
        .add => on & Flag.add != 0 and s.paths.len > 0,
        .quick => on & Flag.quick != 0 and s.paths.len > 0,
        .profile => on & Flag.profiles != 0 and s.paths.len > 0 and profile < (try menuProfiles(a)).len,
        .root => {
            for (subs) |sub| if (try visible(a, sub, s, 0)) return true;
            return on & Flag.profiles != 0 and s.paths.len > 0 and (try menuProfiles(a)).len > 0;
        },
    };
}

fn title(a: Allocator, k: Kind, s: Selection, profile: w.ULONG) Allocator.Error![]const u16 {
    @setEvalBranchQuota(10_000); // the UTF-16 literals below
    const uk = w.GetUserDefaultUILanguage() & 0x3ff == w.LANG_UKRAINIAN; // PRIMARYLANGID; everything else: English
    const cat = std.mem.concat;
    switch (k) {
        .profile => {
            const list = try menuProfiles(a);
            if (profile >= list.len) return L("MakePack");
            const p = list[profile];
            if (p.separate) return cat(a, u16, &.{ if (uk) L("Кожен в окремий ") else L("Each to its own "), p.ext, L(" ("), p.name, L(")") });
            return if (uk)
                cat(a, u16, &.{ L("Додати в «"), archiveBase(s.paths), p.ext, L("» ("), p.name, L(")") })
            else
                cat(a, u16, &.{ L("Add to \""), archiveBase(s.paths), p.ext, L("\" ("), p.name, L(")") });
        },
        .open => return if (uk) L("Відкрити в MakePack") else L("Open with MakePack"),
        .here => return if (uk) L("Розпакувати тут") else L("Extract here"),
        .to => {
            if (s.paths.len != 1) return if (uk) L("Розпакувати кожен в окрему теку") else L("Extract each to its own folder");
            const b = baseName(s.paths[0]);
            return if (uk) cat(a, u16, &.{ L("Розпакувати в «"), b, L("\\»") }) else cat(a, u16, &.{ L("Extract to \""), b, L("\\\"") });
        },
        .add => return if (uk) L("Додати в архів…") else L("Add to archive…"),
        .quick => {
            var buf: [32]u16 = undefined;
            const ext = quickExt(&buf);
            return if (uk)
                cat(a, u16, &.{ L("Додати в «"), archiveBase(s.paths), ext, L("»") })
            else
                cat(a, u16, &.{ L("Add to \""), archiveBase(s.paths), ext, L("\"") });
        },
        .root => return L("MakePack"),
    }
}

/// The folder this DLL (and MakePack.exe) lives in. A null module handle would name the host (Explorer, dllhost)
/// instead, so any failure is error.NoModule and nothing is launched (the C++ used __ImageBase, which cannot fail).
fn dir(a: Allocator) error{ OutOfMemory, NoModule }![]const u16 {
    var self: w.HMODULE = null;
    const flags = w.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | w.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    if (w.GetModuleHandleExW(flags, @ptrCast(&clsid_command), &self) == 0 or self == null) return error.NoModule;
    const buf = try a.alloc(u16, 32768);
    const n = w.GetModuleFileNameW(self, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return error.NoModule;
    return buf[0 .. std.mem.findScalarLast(u16, buf[0..n], '\\') orelse return error.NoModule];
}

fn quote(a: Allocator, p: []const u16) Allocator.Error![]const u16 {
    const tail: []const u16 = if (p.len > 0 and p[p.len - 1] == '\\') L("\\\"") else L("\""); // "C:\" would otherwise escape the closing quote
    return std.mem.concat(a, u16, &.{ L("\""), p, tail });
}

/// MakePack.exe's arguments for one Invoke, one entry per process - the command lines of the classic verbs.
fn commandLines(a: Allocator, k: Kind, s: Selection, profile: w.ULONG) (Allocator.Error || error{ InvalidArg, NotImpl })![]const []const u16 {
    var out: std.ArrayList([]const u16) = .empty;
    if (s.paths.len == 0) return out.items;
    switch (k) {
        .open => try out.append(a, try quote(a, s.paths[0])),
        // one process per archive; MakePack is single-instance and queues them into one progress window
        .here, .to => for (s.paths) |p| {
            try out.append(a, try std.mem.concat(a, u16, &.{ L("x "), try quote(a, p), if (k == .here) L(" --here") else L(" --sub") }));
        },
        // one process for everything; a huge selection is split and MakePack merges the parts (dialog or archive)
        .add, .quick, .profile => {
            const verb: []const u16 = switch (k) {
                .add => L("a"),
                .quick => L("a --quick"),
                else => blk: {
                    const list = try menuProfiles(a);
                    if (profile >= list.len) return error.InvalidArg;
                    break :blk try std.mem.concat(a, u16, &.{ L("a --profile "), try quote(a, list[profile].name) });
                },
            };
            var args: std.ArrayList(u16) = .empty;
            for (s.paths) |p| {
                const q = try std.mem.concat(a, u16, &.{ L(" "), try quote(a, p) });
                if (args.items.len > 0 and args.items.len + q.len > 30000) { // CreateProcess caps the command line at 32767
                    try out.append(a, try std.mem.concat(a, u16, &.{ verb, args.items }));
                    args.clearRetainingCapacity();
                }
                try args.appendSlice(a, q);
            }
            try out.append(a, try std.mem.concat(a, u16, &.{ verb, args.items }));
        },
        .root => return error.NotImpl,
    }
    return out.items;
}

/// `exe` = MakePack.exe's full path, `prefix` = it quoted plus a space (both computed once per Invoke).
fn launch(a: Allocator, exe: [:0]const u16, prefix: []const u16, args: []const u16) Allocator.Error!HRESULT {
    const cmd = try std.mem.concatWithSentinel(a, u16, &.{ prefix, args }, 0);
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi = std.mem.zeroes(w.PROCESS_INFORMATION);
    if (w.CreateProcessW(exe.ptr, cmd.ptr, null, null, 0, 0, null, null, &si, &pi) == 0) {
        const e = w.GetLastError();
        const hr: HRESULT = @bitCast((e & 0xFFFF) | 0x80070000); // HRESULT_FROM_WIN32
        return if (e == 0) S_OK else hr;
    }
    _ = w.CloseHandle(pi.hThread);
    _ = w.CloseHandle(pi.hProcess);
    return S_OK;
}

fn run(a: Allocator, k: Kind, s: Selection, profile: w.ULONG) Allocator.Error!HRESULT {
    const lines = commandLines(a, k, s, profile) catch |e| return switch (e) {
        error.InvalidArg => w.E_INVALIDARG,
        error.NotImpl => w.E_NOTIMPL,
        error.OutOfMemory => error.OutOfMemory,
    };
    if (lines.len == 0) return S_OK;
    const folder = dir(a) catch |e| return switch (e) {
        error.NoModule => w.E_FAIL,
        error.OutOfMemory => error.OutOfMemory,
    };
    const exe = try std.mem.concatWithSentinel(a, u16, &.{ folder, L("\\MakePack.exe") }, 0);
    const prefix = try std.mem.concat(a, u16, &.{ try quote(a, exe), L(" ") });
    var hr: HRESULT = S_OK;
    for (lines) |line| {
        const one = try launch(a, exe, prefix, line);
        if (one < 0) hr = one;
    }
    return hr;
}

// ---- COM plumbing -------------------------------------------------------------------------------

var g_refs: std.atomic.Value(i32) = .init(0); // live objects + IClassFactory::LockServer locks

fn guid(comptime s: []const u8) w.GUID {
    const g = comptime std.os.windows.GUID.parse(s);
    return .{ .Data1 = g.Data1, .Data2 = g.Data2, .Data3 = g.Data3, .Data4 = g.Data4 };
}

fn guidEql(a: w.GUID, b: w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

/// A COM object on the COM heap; counts in g_refs until destroyed.
fn create(v: anytype) ?*@TypeOf(v) {
    const p: *@TypeOf(v) = @ptrCast(@alignCast(w.CoTaskMemAlloc(@sizeOf(@TypeOf(v))) orelse return null));
    p.* = v;
    _ = g_refs.fetchAdd(1, .monotonic);
    return p;
}

/// IUnknown for `T{ iface: I, refs, ... }` made by `create`.
fn Unknown(comptime T: type, comptime I: type, comptime iid: *const w.IID) type {
    return struct {
        fn of(this: [*c]I) *T {
            return @fieldParentPtr("iface", @as(*I, @ptrCast(this)));
        }
        fn queryInterface(this: [*c]I, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) HRESULT {
            if (out == null) return w.E_POINTER;
            out.* = null;
            if (!guidEql(riid.*, w.IID_IUnknown) and !guidEql(riid.*, iid.*)) return w.E_NOINTERFACE;
            out.* = this;
            _ = addRef(this);
            return S_OK;
        }
        fn addRef(this: [*c]I) callconv(.c) w.ULONG {
            return of(this).refs.fetchAdd(1, .monotonic) + 1;
        }
        fn release(this: [*c]I) callconv(.c) w.ULONG {
            const t = of(this);
            const r = t.refs.fetchSub(1, .acq_rel) - 1;
            if (r == 0) {
                w.CoTaskMemFree(t);
                _ = g_refs.fetchSub(1, .release);
            }
            return r;
        }
    };
}

/// One COM call's scratch memory.
fn scratch() std.heap.ArenaAllocator {
    return .init(std.heap.page_allocator);
}

/// SHStrDupW: a CoTaskMemAlloc'd copy the caller frees.
fn strDup(s: []const u16, out: [*c]w.LPWSTR) HRESULT {
    if (out == null) return w.E_POINTER;
    out.* = null;
    const p: [*]u16 = @ptrCast(@alignCast(w.CoTaskMemAlloc((s.len + 1) * 2) orelse return w.E_OUTOFMEMORY));
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    out.* = p;
    return S_OK;
}

const Command = struct {
    iface: w.IExplorerCommand = .{ .lpVtbl = @constCast(&vtbl) },
    refs: std.atomic.Value(u32) = .init(1),
    kind: Kind,
    profile: w.ULONG = 0, // MenuProfiles index for a .profile command

    const U = Unknown(Command, w.IExplorerCommand, &w.IID_IExplorerCommand);
    const vtbl: w.IExplorerCommandVtbl = .{
        .QueryInterface = U.queryInterface,
        .AddRef = U.addRef,
        .Release = U.release,
        .GetTitle = getTitle,
        .GetIcon = getIcon,
        .GetToolTip = getToolTip,
        .GetCanonicalName = getCanonicalName,
        .GetState = getState,
        .Invoke = invoke,
        .GetFlags = getFlags,
        .EnumSubCommands = enumSubCommands,
    };

    fn getTitle(this: [*c]w.IExplorerCommand, items: [*c]w.IShellItemArray, name: [*c]w.LPWSTR) callconv(.c) HRESULT {
        const c = U.of(this);
        var arena = scratch();
        defer arena.deinit();
        const a = arena.allocator();
        return strDup(title(a, c.kind, read(a, items) catch return w.E_OUTOFMEMORY, c.profile) catch return w.E_OUTOFMEMORY, name);
    }
    fn getIcon(this: [*c]w.IExplorerCommand, _: [*c]w.IShellItemArray, icon: [*c]w.LPWSTR) callconv(.c) HRESULT {
        icon.* = null;
        if (U.of(this).kind != .root) return w.E_NOTIMPL; // ponytail: icon on the root only, like Notepad++
        var arena = scratch();
        defer arena.deinit();
        const a = arena.allocator();
        const folder = dir(a) catch |e| return if (e == error.NoModule) w.E_FAIL else w.E_OUTOFMEMORY;
        return strDup(std.mem.concat(a, u16, &.{ folder, L("\\MakePack.exe,0") }) catch return w.E_OUTOFMEMORY, icon);
    }
    fn getToolTip(_: [*c]w.IExplorerCommand, _: [*c]w.IShellItemArray, tip: [*c]w.LPWSTR) callconv(.c) HRESULT {
        tip.* = null;
        return w.E_NOTIMPL;
    }
    fn getCanonicalName(this: [*c]w.IExplorerCommand, out: [*c]w.GUID) callconv(.c) HRESULT {
        out.* = if (U.of(this).kind == .root) clsid_command else std.mem.zeroes(w.GUID);
        return S_OK;
    }
    fn getState(this: [*c]w.IExplorerCommand, items: [*c]w.IShellItemArray, _: w.WINBOOL, state: [*c]w.EXPCMDSTATE) callconv(.c) HRESULT {
        const c = U.of(this);
        state.* = w.ECS_HIDDEN;
        var arena = scratch();
        defer arena.deinit();
        const a = arena.allocator();
        if (visible(a, c.kind, read(a, items) catch return w.E_OUTOFMEMORY, c.profile) catch return w.E_OUTOFMEMORY) state.* = w.ECS_ENABLED;
        return S_OK;
    }
    fn invoke(this: [*c]w.IExplorerCommand, items: [*c]w.IShellItemArray, _: [*c]w.IBindCtx) callconv(.c) HRESULT {
        const c = U.of(this);
        var arena = scratch();
        defer arena.deinit();
        const a = arena.allocator();
        return run(a, c.kind, read(a, items) catch return w.E_OUTOFMEMORY, c.profile) catch w.E_OUTOFMEMORY;
    }
    fn getFlags(this: [*c]w.IExplorerCommand, flags: [*c]w.EXPCMDFLAGS) callconv(.c) HRESULT {
        flags.* = if (U.of(this).kind == .root) w.ECF_HASSUBCOMMANDS else w.ECF_DEFAULT;
        return S_OK;
    }
    fn enumSubCommands(this: [*c]w.IExplorerCommand, out: [*c][*c]w.IEnumExplorerCommand) callconv(.c) HRESULT {
        out.* = null;
        if (U.of(this).kind != .root) return w.E_NOTIMPL;
        var arena = scratch();
        defer arena.deinit();
        const profiles = menuProfiles(arena.allocator()) catch return w.E_OUTOFMEMORY;
        const e = create(SubCommands{ .total = @intCast(subs.len + profiles.len) }) orelse return w.E_OUTOFMEMORY;
        out.* = &e.iface;
        return S_OK;
    }
};

const SubCommands = struct {
    iface: w.IEnumExplorerCommand = .{ .lpVtbl = @constCast(&vtbl) },
    refs: std.atomic.Value(u32) = .init(1),
    pos: w.ULONG = 0,
    total: w.ULONG, // fixed for this menu's lifetime

    const U = Unknown(SubCommands, w.IEnumExplorerCommand, &w.IID_IEnumExplorerCommand);
    const vtbl: w.IEnumExplorerCommandVtbl = .{
        .QueryInterface = U.queryInterface,
        .AddRef = U.addRef,
        .Release = U.release,
        .Next = next,
        .Skip = skip,
        .Reset = reset,
        .Clone = clone,
    };

    fn next(this: [*c]w.IEnumExplorerCommand, want: w.ULONG, out: [*c][*c]w.IExplorerCommand, got: [*c]w.ULONG) callconv(.c) HRESULT {
        const e = U.of(this);
        var n: w.ULONG = 0;
        while (n < want and e.pos < e.total) : (n += 1) {
            const c = create(if (e.pos < subs.len) Command{ .kind = subs[e.pos] } else Command{ .kind = .profile, .profile = e.pos - @as(w.ULONG, subs.len) }) orelse break;
            out[n] = &c.iface;
            e.pos += 1;
        }
        if (got != null) got.* = n;
        return if (n == want) S_OK else w.S_FALSE;
    }
    fn skip(this: [*c]w.IEnumExplorerCommand, n: w.ULONG) callconv(.c) HRESULT {
        const e = U.of(this);
        e.pos = @min(e.pos +| n, e.total);
        return S_OK;
    }
    fn reset(this: [*c]w.IEnumExplorerCommand) callconv(.c) HRESULT {
        U.of(this).pos = 0;
        return S_OK;
    }
    fn clone(_: [*c]w.IEnumExplorerCommand, out: [*c][*c]w.IEnumExplorerCommand) callconv(.c) HRESULT {
        out.* = null;
        return w.E_NOTIMPL;
    }
};

const Factory = struct {
    iface: w.IClassFactory = .{ .lpVtbl = @constCast(&vtbl) },
    refs: std.atomic.Value(u32) = .init(1),

    const U = Unknown(Factory, w.IClassFactory, &w.IID_IClassFactory);
    const vtbl: w.IClassFactoryVtbl = .{
        .QueryInterface = U.queryInterface,
        .AddRef = U.addRef,
        .Release = U.release,
        .CreateInstance = createInstance,
        .LockServer = lockServer,
    };

    fn createInstance(_: [*c]w.IClassFactory, outer: [*c]w.IUnknown, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        if (outer != null) return w.CLASS_E_NOAGGREGATION;
        const c = create(Command{ .kind = .root }) orelse return w.E_OUTOFMEMORY;
        const hr = Command.U.queryInterface(&c.iface, riid, out);
        _ = Command.U.release(&c.iface);
        return hr;
    }
    fn lockServer(_: [*c]w.IClassFactory, lock: w.WINBOOL) callconv(.c) HRESULT {
        _ = if (lock != 0) g_refs.fetchAdd(1, .monotonic) else g_refs.fetchSub(1, .release);
        return S_OK;
    }
};

export fn DllGetClassObject(clsid: [*c]const w.CLSID, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) HRESULT {
    out.* = null;
    if (!guidEql(clsid.*, clsid_command)) return w.CLASS_E_CLASSNOTAVAILABLE;
    const f = create(Factory{}) orelse return w.E_OUTOFMEMORY;
    const hr = Factory.U.queryInterface(&f.iface, riid, out);
    _ = Factory.U.release(&f.iface);
    return hr;
}

export fn DllCanUnloadNow() callconv(.c) HRESULT {
    return if (g_refs.load(.acquire) == 0) S_OK else w.S_FALSE;
}

// ---- tests (zig build test-shell also runs shell/test/harness.cpp against the built DLL) ---------

const testing = std.testing;

/// A UTF-8 literal as a NUL-terminated UTF-16 slice (tests only).
fn u(a: Allocator, s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch unreachable;
}

fn expectU(want: []const u8, got: []const u16) !void {
    var buf: [1024]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buf, got) catch return error.TestUnexpectedResult;
    try testing.expectEqualStrings(want, buf[0..n]);
}

test "fileName / extension behave like PathFindFileNameW / PathFindExtensionW" {
    var arena = scratch();
    defer arena.deinit();
    const a = arena.allocator();
    try expectU("a.zip", fileName(u(a, "C:\\x\\a.zip")));
    try expectU("x\\", fileName(u(a, "C:\\x\\")));
    try expectU("C:\\", fileName(u(a, "C:\\")));
    try expectU("b", fileName(u(a, "C:/a/b")));
    try expectU(".gz", extension(u(a, "C:\\x\\Звіт за травень 2026.tar.gz")));
    try expectU("", extension(u(a, "C:\\x.zip\\noext")));
    try expectU("", extension(u(a, "C:\\x\\a.zip copy")));
    try testing.expect(isArchive(u(a, "C:\\x\\A.ZIP")) and isArchive(u(a, "C:\\x\\b.tar.gz")) and isArchive(u(a, "C:\\p.7z.001")));
    try testing.expect(!isArchive(u(a, "C:\\x\\c.txt")) and !isArchive(u(a, "C:\\x\\zip")) and !isArchive(u(a, "C:\\x\\.zipx.bak")));
}

test "baseName (Engine.BaseName) and archiveBase (Engine.DefaultArchivePath)" {
    var arena = scratch();
    defer arena.deinit();
    const a = arena.allocator();
    try expectU("Звіт за травень 2026", baseName(u(a, "C:\\x\\Звіт за травень 2026.tar.gz")));
    try expectU("a", baseName(u(a, "C:\\x\\a.TGZ")));
    try expectU("b", baseName(u(a, "C:\\x\\b.zip")));
    try expectU("p.7z", baseName(u(a, "C:\\x\\p.7z.001")));
    try expectU("noext", baseName(u(a, "C:\\x\\noext")));
    try expectU("", baseName(u(a, "C:\\x\\.hidden")));

    // A file (or a path that does not exist) loses its last extension; a folder keeps its whole name.
    var tmp: [261]u16 = undefined;
    var rnd: [4]u8 = undefined;
    testing.io.random(&rnd);
    const parent = try std.mem.concatWithSentinel(a, u16, &.{ tmp[0..w.GetTempPathW(tmp.len, &tmp)], u(a, "makepack-test-"), u(a, &std.fmt.bytesToHex(rnd, .lower)) }, 0);
    const folder = try std.mem.concatWithSentinel(a, u16, &.{ parent, u(a, "\\v1.2 data.d") }, 0);
    try testing.expect(w.CreateDirectoryW(parent.ptr, null) != 0);
    defer _ = w.RemoveDirectoryW(parent.ptr);
    try testing.expect(w.CreateDirectoryW(folder.ptr, null) != 0);
    defer _ = w.RemoveDirectoryW(folder.ptr);
    try expectU("v1.2 data.d", archiveBase(&.{folder}));
    try expectU("Звіт за травень 2026.tar", archiveBase(&.{u(a, "C:\\nowhere-makepack\\Звіт за травень 2026.tar.gz")}));
    try expectU(".hidden", archiveBase(&.{u(a, "C:\\nowhere-makepack\\.hidden")}));
    try expectU("b", archiveBase(&.{ u(a, "C:\\a\\b\\x.txt"), u(a, "C:\\a\\b\\y") }));
    try expectU("share", archiveBase(&.{ u(a, "\\\\srv\\share\\x"), u(a, "\\\\srv\\share\\y") }));
    try expectU("MakePack", archiveBase(&.{ u(a, "C:\\x.txt"), u(a, "C:\\y.txt") })); // drive root
    try expectU("MakePack", archiveBase(&.{}));
}

test "commandLines: same CLI as the classic verbs, split before 30000 chars" {
    var arena = scratch();
    defer arena.deinit();
    const a = arena.allocator();
    const three: []const [:0]const u16 = &.{ u(a, "C:\\a.zip"), u(a, "C:\\Звіт.tar.gz"), u(a, "D:\\") };
    const sel: Selection = .{ .count = 3, .paths = three };

    const open = try commandLines(a, .open, sel, 0);
    try testing.expectEqual(1, open.len);
    try expectU("\"C:\\a.zip\"", open[0]);
    const here = try commandLines(a, .here, sel, 0);
    try testing.expectEqual(3, here.len);
    try expectU("x \"C:\\Звіт.tar.gz\" --here", here[1]);
    try expectU("x \"D:\\\\\" --here", here[2]); // trailing backslash doubled
    try expectU("x \"C:\\a.zip\" --sub", (try commandLines(a, .to, sel, 0))[0]);
    const add = try commandLines(a, .add, sel, 0);
    try testing.expectEqual(1, add.len);
    try expectU("a \"C:\\a.zip\" \"C:\\Звіт.tar.gz\" \"D:\\\\\"", add[0]);
    try expectU("a --quick \"C:\\a.zip\" \"C:\\Звіт.tar.gz\" \"D:\\\\\"", (try commandLines(a, .quick, sel, 0))[0]);
    try testing.expectEqual(0, (try commandLines(a, .add, .{ .count = 1 }, 0)).len); // nothing with a file-system path
    try testing.expectError(error.NotImpl, commandLines(a, .root, sel, 0));

    // " \"" + 2997 chars + "\"" = 3000 per path: ten fit exactly (30000 is not > 30000), the eleventh starts a new process.
    const long = try a.alloc(u16, 2997);
    @memset(long, 'x');
    var many: [11][:0]const u16 = undefined;
    for (&many, 0..) |*p, i| {
        long[0] = 'a' + @as(u16, @intCast(i));
        p.* = try a.dupeSentinel(u16, long, 0);
    }
    for ([_]usize{ 10, 11 }, [_]usize{ 1, 2 }) |n, want| {
        const lines = try commandLines(a, .quick, .{ .count = @intCast(n), .paths = many[0..n] }, 0);
        try testing.expectEqual(want, lines.len);
        var seen: usize = 0;
        for (lines) |line| {
            try testing.expect(std.mem.startsWith(u16, line, L("a --quick \"")));
            try testing.expect(line.len - "a --quick".len <= 30000);
            seen += std.mem.count(u16, line, L("xxx\""));
        }
        try testing.expectEqual(n, seen); // every path exactly once
    }
}

test "dir: the folder of the module holding this code (here the test exe), never the host's" {
    var arena = scratch();
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [32768]u16 = undefined;
    const host = buf[0..w.GetModuleFileNameW(null, &buf, buf.len)];
    try testing.expectEqualSlices(u16, host[0..std.mem.findScalarLast(u16, host, '\\').?], try dir(a));
}

test "COM lifetime: every object counts until its last Release (DllCanUnloadNow)" {
    // HKCU -> a throw-away key, so EnumSubCommands sees no MenuProfiles of the real user.
    var key: w.HKEY = null;
    var rnd: [4]u8 = undefined;
    testing.io.random(&rnd);
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "Software\\MakePackTest-shell-{x}", .{rnd});
    const wname = u(testing.allocator, name);
    defer testing.allocator.free(wname);
    try testing.expectEqual(0, w.RegCreateKeyExW(hkcu(), wname, 0, null, 0, w.KEY_ALL_ACCESS, null, &key, null));
    defer {
        _ = w.RegOverridePredefKey(hkcu(), null);
        _ = w.RegCloseKey(key);
        _ = w.RegDeleteTreeW(hkcu(), wname);
    }
    try testing.expectEqual(0, w.RegOverridePredefKey(hkcu(), key));

    var other = clsid_command;
    other.Data1 +%= 1;
    var p: ?*anyopaque = null;
    try testing.expectEqual(w.CLASS_E_CLASSNOTAVAILABLE, DllGetClassObject(&other, &w.IID_IClassFactory, &p));

    try testing.expectEqual(S_OK, DllCanUnloadNow());
    // A LockServer(TRUE) keeps the DLL even without any object.
    try testing.expectEqual(S_OK, DllGetClassObject(&clsid_command, &w.IID_IClassFactory, &p));
    var f: [*c]w.IClassFactory = @ptrCast(@alignCast(p));
    try testing.expectEqual(S_OK, f.*.lpVtbl.*.LockServer.?(f, 1));
    try testing.expectEqual(0, f.*.lpVtbl.*.Release.?(f));
    try testing.expectEqual(w.S_FALSE, DllCanUnloadNow());
    try testing.expectEqual(S_OK, DllGetClassObject(&clsid_command, &w.IID_IUnknown, &p));
    f = @ptrCast(@alignCast(p));
    try testing.expectEqual(S_OK, f.*.lpVtbl.*.LockServer.?(f, 0));
    try testing.expectEqual(w.E_NOINTERFACE, f.*.lpVtbl.*.CreateInstance.?(f, null, &w.IID_IShellItem, &p));
    try testing.expect(p == null);
    try testing.expectEqual(S_OK, f.*.lpVtbl.*.CreateInstance.?(f, null, &w.IID_IExplorerCommand, &p));
    const root: [*c]w.IExplorerCommand = @ptrCast(@alignCast(p));
    try testing.expectEqual(0, f.*.lpVtbl.*.Release.?(f));
    try testing.expectEqual(w.S_FALSE, DllCanUnloadNow()); // root

    var flags: w.EXPCMDFLAGS = 0;
    _ = root.*.lpVtbl.*.GetFlags.?(root, &flags);
    try testing.expectEqual(@as(w.EXPCMDFLAGS, w.ECF_HASSUBCOMMANDS), flags);
    var canon: w.GUID = undefined;
    _ = root.*.lpVtbl.*.GetCanonicalName.?(root, &canon);
    try testing.expect(guidEql(canon, clsid_command));
    var t: w.LPWSTR = null;
    try testing.expectEqual(S_OK, root.*.lpVtbl.*.GetTitle.?(root, null, &t));
    try expectU("MakePack", std.mem.span(t));
    w.CoTaskMemFree(t);
    var st: w.EXPCMDSTATE = w.ECS_ENABLED;
    _ = root.*.lpVtbl.*.GetState.?(root, null, 1, &st);
    try testing.expectEqual(@as(w.EXPCMDSTATE, w.ECS_HIDDEN), st); // nothing selected

    var e: [*c]w.IEnumExplorerCommand = null;
    try testing.expectEqual(S_OK, root.*.lpVtbl.*.EnumSubCommands.?(root, &e));
    var cmds: [8][*c]w.IExplorerCommand = @splat(null);
    var got: w.ULONG = 0;
    try testing.expectEqual(w.S_FALSE, e.*.lpVtbl.*.Next.?(e, 8, &cmds, &got));
    try testing.expectEqual(5, got); // Open, Here, To, Add, Quick; no MenuProfiles
    try testing.expectEqual(w.S_FALSE, e.*.lpVtbl.*.Next.?(e, 1, &cmds[5], null));
    try testing.expectEqual(S_OK, e.*.lpVtbl.*.Reset.?(e));
    try testing.expectEqual(S_OK, e.*.lpVtbl.*.Skip.?(e, 0xFFFFFFFF));
    try testing.expectEqual(0, e.*.lpVtbl.*.Release.?(e));
    var none: [*c]w.IEnumExplorerCommand = undefined;
    try testing.expectEqual(w.E_NOTIMPL, cmds[0].*.lpVtbl.*.EnumSubCommands.?(cmds[0], &none));
    try testing.expect(none == null);
    var sub_flags: w.EXPCMDFLAGS = 1;
    _ = cmds[0].*.lpVtbl.*.GetFlags.?(cmds[0], &sub_flags);
    try testing.expectEqual(@as(w.EXPCMDFLAGS, w.ECF_DEFAULT), sub_flags);
    try testing.expectEqual(0, root.*.lpVtbl.*.Release.?(root));
    try testing.expectEqual(w.S_FALSE, DllCanUnloadNow()); // the five subcommands are still alive
    for (cmds[0..got]) |c| try testing.expectEqual(0, c.*.lpVtbl.*.Release.?(c));
    try testing.expectEqual(S_OK, DllCanUnloadNow());
}
