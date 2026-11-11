//! MP-G1: the Windows shell bits of the main window that do not draw (Shell.cs ShellInfo, MainForm's clipboard,
//! paste, Properties, shell open, the folder watcher). No ImGui here: the selftest "gui" check uses it too.
//! UI thread only unless a function says otherwise.
const std = @import("std");
const kit = @import("kit");
const S = @import("../strings.zig");
const pw = @import("../platform/platform_win.zig");
const engine = @import("../core/engine.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
/// Process-lifetime caches (a few hundred extensions at most) and helper scratch.
const cache_gpa = std.heap.smp_allocator;

// ---- type names, drives, times ----------------------------------------------------------------------

var types: std.StringHashMapUnmanaged([]const u8) = .empty;
var drive_names: std.StringHashMapUnmanaged([]const u8) = .empty;

/// ShellInfo.Of(...).Type: Explorer's type name ("Text Document", "<folder>" fallback), cached per extension.
/// Explorer names types in the Windows display language: when MakePack is in another one, its own names
/// ("<folder>", "TXT File") keep the column in one language.
pub fn typeName(name: []const u8, folder: bool) []const u8 {
    const lang = kit.i18n.current();
    if (kit.i18n.fromLangId(w.GetUserDefaultUILanguage()) != lang) return ownType(lang, folder, pw.extension(name));
    const ext = if (folder) "\\folder" else pw.extension(name);
    var kbuf: [64]u8 = undefined;
    const key_src = if (!folder and ext.len == 0) "\\noext" else ext;
    if (key_src.len > kbuf.len) return upperExt(ext);
    const key = std.ascii.lowerString(&kbuf, key_src);
    if (types.get(key)) |t| return t;
    var info = std.mem.zeroes(w.SHFILEINFOW);
    var pbuf: [80]u8 = undefined;
    const probe: []const u8 = if (folder) "folder" else std.mem.print(&pbuf, "file{s}", .{ext}) catch "file";
    const wp = kit.win.toW(cache_gpa, probe) catch return fallbackType(folder, ext);
    defer cache_gpa.free(wp);
    const attr: w.DWORD = if (folder) w.FILE_ATTRIBUTE_DIRECTORY else w.FILE_ATTRIBUTE_NORMAL;
    var t: []const u8 = fallbackType(folder, ext);
    if (w.SHGetFileInfoW(wp.ptr, attr, &info, @sizeOf(w.SHFILEINFOW), w.SHGFI_TYPENAME | w.SHGFI_USEFILEATTRIBUTES) != 0 and info.szTypeName[0] != 0)
        t = kit.win.fromWZ(cache_gpa, @ptrCast(&info.szTypeName)) catch t;
    const k = cache_gpa.dupe(u8, key) catch return t;
    types.put(cache_gpa, k, t) catch {};
    return t;
}

var own_types: std.StringHashMapUnmanaged([]const u8) = .empty;

/// "<folder>" | "TXT File" in `lang` (cached per language and extension: rows keep the slice).
fn ownType(lang: kit.i18n.Lang, folder: bool, ext: []const u8) []const u8 {
    if (folder) return S.tr().folderType;
    const e = std.mem.trimStart(u8, ext, ".");
    if (e.len == 0) return "";
    var kbuf: [80]u8 = undefined;
    if (e.len > 64) return upperExt(e);
    const key = std.ascii.lowerString(&kbuf, std.mem.print(&kbuf, "{s}:{s}", .{ lang.code(), e }) catch return upperExt(e));
    if (own_types.get(key)) |t| return t;
    var ub: [64]u8 = undefined;
    var tb: [200]u8 = undefined;
    const t = cache_gpa.dupe(u8, S.fillZ(&tb, S.tr().fileTypeFmt, .{std.ascii.upperString(&ub, e)})) catch return upperExt(e);
    const k = cache_gpa.dupe(u8, key) catch return t;
    own_types.put(cache_gpa, k, t) catch {};
    return t;
}

fn fallbackType(folder: bool, ext: []const u8) []const u8 {
    return if (folder) S.tr().folderType else upperExt(ext);
}

/// "TXT" for ".txt" (process-lifetime string).
fn upperExt(ext: []const u8) []const u8 {
    const e = std.mem.trimStart(u8, ext, ".");
    const u = cache_gpa.alloc(u8, e.len) catch return "";
    return std.ascii.upperString(u, e);
}

/// DriveInfo.GetDrives(): "C:\", "D:\", ... (into `out`, slices of process-lifetime strings).
pub fn drives(gpa: Allocator) ![][]const u8 {
    var wb: [512]u16 = undefined;
    const n = w.GetLogicalDriveStringsW(wb.len, &wb);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u16, wb[0..@min(n, wb.len)], 0);
    while (it.next()) |d| if (d.len > 0) try list.append(gpa, try kit.win.fromW(gpa, d));
    return list.toOwnedSlice(gpa);
}

/// ShellInfo.DriveName: "Local Disk (C:)" - what Explorer calls a drive (cached).
pub fn driveName(root: []const u8) []const u8 {
    if (drive_names.get(root)) |n| return n;
    var info = std.mem.zeroes(w.SHFILEINFOW);
    var name: []const u8 = root;
    if (kit.win.toW(cache_gpa, root)) |wp| {
        defer cache_gpa.free(wp);
        if (w.SHGetFileInfoW(wp.ptr, 0, &info, @sizeOf(w.SHFILEINFOW), w.SHGFI_DISPLAYNAME) != 0 and info.szDisplayName[0] != 0)
            name = kit.win.fromWZ(cache_gpa, @ptrCast(&info.szDisplayName)) catch root;
    } else |_| {}
    const k = cache_gpa.dupe(u8, root) catch return name;
    if (name.ptr == root.ptr) name = k;
    drive_names.put(cache_gpa, k, name) catch {};
    return name;
}

/// DateTime.ToString("g") of a FILETIME (UTC ticks): the user's short date + short time, local time.
pub fn timeText(buf: []u8, ticks: u64) []const u8 {
    if (ticks == 0) return "";
    const ft: w.FILETIME = .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
    var utc: w.SYSTEMTIME = undefined;
    var local: w.SYSTEMTIME = undefined;
    if (w.FileTimeToSystemTime(&ft, &utc) == 0) return "";
    if (w.SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) local = utc;
    var wb: [128]u16 = undefined;
    const d = w.GetDateFormatEx(null, w.DATE_SHORTDATE, &local, null, &wb, 64, null);
    if (d <= 0) return "";
    const dn: usize = @intCast(d);
    wb[dn - 1] = ' ';
    const t = w.GetTimeFormatEx(null, w.TIME_NOSECONDS, &local, null, wb[dn..].ptr, @intCast(wb.len - dn));
    const total: usize = if (t > 0) dn + @as(usize, @intCast(t)) - 1 else dn - 1;
    var out: std.Io.Writer = .fixed(buf);
    var it = std.unicode.Wtf16LeIterator.init(wb[0..total]);
    while (it.nextCodepoint()) |cp| {
        var e: [4]u8 = undefined;
        const len = std.unicode.wtf8Encode(cp, &e) catch continue;
        out.writeAll(e[0..len]) catch break;
    }
    return out.buffered();
}

/// String.Compare(a, b, CurrentCultureIgnoreCase) (the list's sorter).
pub fn compareText(a: []const u8, b: []const u8) std.math.Order {
    var wa: [512]u16 = undefined;
    var wb: [512]u16 = undefined;
    const la = std.unicode.wtf8ToWtf16Le(&wa, a[0..@min(a.len, 500)]) catch return std.mem.order(u8, a, b);
    const lb = std.unicode.wtf8ToWtf16Le(&wb, b[0..@min(b.len, 500)]) catch return std.mem.order(u8, a, b);
    const r = w.CompareStringEx(null, w.LINGUISTIC_IGNORECASE, &wa, @intCast(la), &wb, @intCast(lb), null, null, 0);
    return switch (r) {
        w.CSTR_LESS_THAN => .lt,
        w.CSTR_GREATER_THAN => .gt,
        w.CSTR_EQUAL => .eq,
        else => std.mem.order(u8, a, b),
    };
}

/// OrdinalIgnoreCase key: the name upper-cased the way the file system folds it.
pub fn upperKey(gpa: Allocator, s: []const u8) ![]u8 {
    const ws = try kit.win.toW(gpa, s);
    defer gpa.free(ws);
    if (ws.len > 0) _ = w.CharUpperBuffW(ws.ptr, @intCast(ws.len));
    return kit.win.fromW(gpa, ws);
}

// ---- shell actions ------------------------------------------------------------------------------------

/// Process.Start(path, UseShellExecute): open in its own app.
pub fn open(gpa: Allocator, path: []const u8) !void {
    _ = try kit.win.shellExecute(gpa, .{ .file = path });
}

/// ShellInfo.Properties: Explorer's own Properties sheet.
pub fn properties(gpa: Allocator, path: []const u8) void {
    const wp = kit.win.toW(gpa, path) catch return;
    defer gpa.free(wp);
    _ = w.SHObjectProperties(null, w.SHOP_FILEPATH, wp.ptr, null);
}

/// ShellInfo.Copy: copy (or move) files into a folder with the shell's own progress and "file exists"
/// dialogs. Pasting a folder's own files back into it makes "name - Copy", as Explorer does.
pub fn copy(gpa: Allocator, owner: w.HWND, paths: []const []const u8, dest: []const u8, move: bool) bool {
    if (paths.len == 0) return true;
    var from: std.ArrayList(u16) = .empty;
    defer from.deinit(gpa);
    var same = true;
    for (paths) |p| {
        const full = engine.fullPath(gpa, std.mem.trimEnd(u8, p, "\\/")) catch continue;
        defer gpa.free(full);
        if (!engine.samePath(pw.directoryName(full) orelse "", dest)) same = false;
        const wp = kit.win.toW(gpa, full) catch return false;
        defer gpa.free(wp);
        from.appendSlice(gpa, wp[0 .. wp.len + 1]) catch return false;
    }
    from.append(gpa, 0) catch return false;
    const to = kit.win.toW(gpa, dest) catch return false;
    defer gpa.free(to);
    var to2 = gpa.alloc(u16, to.len + 2) catch return false;
    defer gpa.free(to2);
    @memcpy(to2[0..to.len], to);
    to2[to.len] = 0;
    to2[to.len + 1] = 0;
    var op = std.mem.zeroes(w.SHFILEOPSTRUCTW);
    op.hwnd = owner;
    op.wFunc = if (move) w.FO_MOVE else w.FO_COPY;
    op.pFrom = from.items.ptr;
    op.pTo = to2.ptr;
    op.fFlags = @intCast(w.FOF_ALLOWUNDO | (if (same and !move) w.FOF_RENAMEONCOLLISION else 0));
    return w.SHFileOperationW(&op) == 0 and op.fAnyOperationsAborted == 0;
}

/// Directory.Move / File.Move in the same folder (F2 on disk).
pub fn rename(gpa: Allocator, from: []const u8, to: []const u8) !void {
    const a = try kit.win.toW(gpa, from);
    defer gpa.free(a);
    const b = try kit.win.toW(gpa, to);
    defer gpa.free(b);
    if (w.MoveFileExW(a.ptr, b.ptr, 0) == 0) return winError(w.GetLastError());
}

/// Directory.CreateDirectory (one level).
pub fn makeDir(gpa: Allocator, path: []const u8) !void {
    const a = try kit.win.toW(gpa, path);
    defer gpa.free(a);
    if (w.CreateDirectoryW(a.ptr, null) == 0) return winError(w.GetLastError());
}

fn winError(e: w.DWORD) anyerror {
    return switch (e) {
        w.ERROR_ACCESS_DENIED => error.AccessDenied,
        w.ERROR_ALREADY_EXISTS, w.ERROR_FILE_EXISTS => error.PathAlreadyExists,
        w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND => error.FileNotFound,
        w.ERROR_SHARING_VIOLATION => error.FileBusy,
        w.ERROR_INVALID_NAME => error.BadPathName,
        else => error.Unexpected,
    };
}

// ---- clipboard ----------------------------------------------------------------------------------------

/// MainForm.ToClipboard: OpenClipboard gives up at once while another process holds it (rdpclip under Remote
/// Desktop often does for a moment): 30 tries x 100 ms ride that out.
fn openClipboard(owner: w.HWND) bool {
    for (0..30) |_| {
        if (w.OpenClipboard(owner) != 0) return true;
        w.Sleep(100);
    }
    return false;
}

fn globalOf(bytes: []const u8) w.HGLOBAL {
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes.len);
    if (h == null) return null;
    const p: [*]u8 = @ptrCast(w.GlobalLock(h) orelse {
        _ = w.GlobalFree(h);
        return null;
    });
    @memcpy(p[0..bytes.len], bytes);
    _ = w.GlobalUnlock(h);
    return h;
}

/// CF_HDROP payload: DROPFILES + the wide paths, double-NUL terminated (a new HGLOBAL; null on failure).
pub fn hdrop(gpa: Allocator, paths: []const []const u8) w.HGLOBAL {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var df = std.mem.zeroes(w.DROPFILES);
    df.pFiles = @sizeOf(w.DROPFILES);
    df.fWide = 1;
    buf.appendSlice(gpa, std.mem.asBytes(&df)) catch return null;
    for (paths) |p| {
        const wp = kit.win.toW(gpa, p) catch return null;
        defer gpa.free(wp);
        buf.appendSlice(gpa, std.mem.sliceAsBytes(wp[0 .. wp.len + 1])) catch return null;
    }
    buf.appendSlice(gpa, &.{ 0, 0 }) catch return null;
    return globalOf(buf.items);
}

pub fn preferredDropEffect() w.UINT {
    return w.RegisterClipboardFormatW(kit.win.L("Preferred DropEffect"));
}

/// Clipboard.SetText (CF_UNICODETEXT). False = the clipboard stayed busy (nothing copied, nothing lost).
pub fn setText(gpa: Allocator, owner: w.HWND, text: []const u8) bool {
    const wt = kit.win.toW(gpa, text) catch return false;
    defer gpa.free(wt);
    const h = globalOf(std.mem.sliceAsBytes(wt[0 .. wt.len + 1]));
    if (h == null) return false;
    if (!openClipboard(owner)) {
        _ = w.GlobalFree(h);
        return false;
    }
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    if (w.SetClipboardData(w.CF_UNICODETEXT, h) == null) {
        _ = w.GlobalFree(h);
        return false;
    }
    return true;
}

/// A DataObject with FileDrop + "Preferred DropEffect" = copy (what Explorer pastes).
pub fn setFiles(gpa: Allocator, owner: w.HWND, paths: []const []const u8) bool {
    const h = hdrop(gpa, paths);
    if (h == null) return false;
    const eff: u32 = 1; // DROPEFFECT_COPY
    const e = globalOf(std.mem.asBytes(&eff));
    if (!openClipboard(owner)) {
        _ = w.GlobalFree(h);
        if (e != null) _ = w.GlobalFree(e);
        return false;
    }
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    if (w.SetClipboardData(w.CF_HDROP, h) == null) _ = w.GlobalFree(h);
    if (e != null and w.SetClipboardData(preferredDropEffect(), e) == null) _ = w.GlobalFree(e);
    return true;
}

pub fn hasFiles() bool {
    return w.IsClipboardFormatAvailable(w.CF_HDROP) != 0;
}

pub const Pasted = struct {
    files: [][]u8,
    /// Explorer's Cut: "Preferred DropEffect" has DROPEFFECT_MOVE.
    move: bool,

    pub fn deinit(p: Pasted, gpa: Allocator) void {
        for (p.files) |f| gpa.free(f);
        gpa.free(p.files);
    }
};

/// Clipboard.GetData(FileDrop): null when there are no files.
pub fn getFiles(gpa: Allocator, owner: w.HWND) ?Pasted {
    if (!hasFiles() or !openClipboard(owner)) return null;
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_HDROP) orelse return null;
    const drop: w.HDROP = @ptrCast(@alignCast(h));
    const n = w.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    if (n == 0) return null;
    var list: std.ArrayList([]u8) = .empty;
    for (0..n) |i| {
        var wb: [32768]u16 = undefined;
        const len = w.DragQueryFileW(drop, @intCast(i), &wb, wb.len);
        const s = kit.win.fromW(gpa, wb[0..len]) catch continue;
        list.append(gpa, s) catch gpa.free(s);
    }
    var move = false;
    if (w.GetClipboardData(preferredDropEffect())) |e| {
        if (w.GlobalLock(e)) |p| {
            if (w.GlobalSize(e) >= 4) move = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(p)), .little) & 2 != 0;
            _ = w.GlobalUnlock(e);
        }
    }
    const files = list.toOwnedSlice(gpa) catch {
        for (list.items) |f| gpa.free(f);
        list.deinit(gpa);
        return null;
    };
    if (files.len == 0) {
        gpa.free(files);
        return null;
    }
    return .{ .files = files, .move = move };
}

// ---- folder watcher -----------------------------------------------------------------------------------

/// FileSystemWatcher + the 400 ms refresh timer: a thread waits on FindFirstChangeNotification and, once the
/// folder has been quiet for 400 ms, raises `changed` and wakes the app. One folder at a time.
pub const Watcher = struct {
    thread: ?std.Thread = null,
    stop_ev: w.HANDLE = null,
    changed: std.atomic.Value(bool) = .init(false),
    dir: ?[:0]u16 = null,

    pub fn watch(wt: *Watcher, gpa: Allocator, dir: []const u8) void {
        wt.stop(gpa);
        wt.dir = kit.win.toW(gpa, dir) catch return;
        wt.stop_ev = w.CreateEventW(null, 1, 0, null);
        if (wt.stop_ev == null) return;
        wt.thread = std.Thread.spawn(.{}, run, .{wt}) catch null;
    }

    pub fn stop(wt: *Watcher, gpa: Allocator) void {
        if (wt.thread) |t| {
            _ = w.SetEvent(wt.stop_ev);
            t.join();
        }
        wt.thread = null;
        if (wt.stop_ev != null) _ = w.CloseHandle(wt.stop_ev);
        wt.stop_ev = null;
        if (wt.dir) |d| gpa.free(d);
        wt.dir = null;
        wt.changed.store(false, .release);
    }

    /// UI thread: true once per quiet-after-change.
    pub fn take(wt: *Watcher) bool {
        return wt.changed.swap(false, .acq_rel);
    }

    fn run(wt: *Watcher) void {
        const flags: w.DWORD = @intCast(w.FILE_NOTIFY_CHANGE_FILE_NAME | w.FILE_NOTIFY_CHANGE_DIR_NAME |
            w.FILE_NOTIFY_CHANGE_SIZE | w.FILE_NOTIFY_CHANGE_LAST_WRITE);
        const h = w.FindFirstChangeNotificationW(wt.dir.?.ptr, 0, flags);
        if (h == w.INVALID_HANDLE_VALUE) return; // a drive that cannot be watched: refresh by navigating
        defer _ = w.FindCloseChangeNotification(h);
        const handles = [2]w.HANDLE{ wt.stop_ev, h };
        while (true) {
            if (w.WaitForMultipleObjects(2, &handles, 0, w.INFINITE) != w.WAIT_OBJECT_0 + 1) return;
            _ = w.FindNextChangeNotification(h);
            while (true) { // the timer restarts on every event
                const r = w.WaitForMultipleObjects(2, &handles, 0, 400);
                if (r == w.WAIT_TIMEOUT) break;
                if (r != w.WAIT_OBJECT_0 + 1) return;
                _ = w.FindNextChangeNotification(h);
            }
            wt.changed.store(true, .release);
            kit.app.wakeGlobal();
        }
    }
};
