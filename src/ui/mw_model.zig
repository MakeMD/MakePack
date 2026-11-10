//! MP-G1: the main window's state without any drawing (MainForm.cs: locations, rows, history, nested archives,
//! folder sizes, the status / address / title texts, selection). main_window.zig draws it and turns its Actions
//! into dialogs; the selftest "gui" check drives it directly (no window, no dialogs).
//! Every navigation goes through `goWith`: it copies the target first (a Loc may point into the model itself).
//! An archive that is not open yet is never opened here (the UI thread would hang on a big one): the target goes
//! to `want` with error.NeedOpen, the window hands it to Dialogs.openArchive (a job with progress and Cancel; its
//! alerts and prompts say what is wrong) and comes back with `goWith(want, opened)`.
const std = @import("std");
const kit = @import("kit");
const engine = @import("../core/engine.zig");
const types = @import("../core/types.zig");
const S = @import("../strings.zig");
const pw = @import("../platform/platform_win.zig");
const shell = @import("mw_shell.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const w = kit.w;
const eqlI = types.eqlIgnoreCase;

/// MainForm.ParentArc: the archive a nested one was opened from (it lives in a temp file), to go back to on "..".
pub const ParentArc = struct { source: []const u8, password: ?[]const u8 = null, cur: []const u8 = "" };

/// MainForm.Loc: a folder (inner null) or an archive plus the folder inside it ("" or "a/b/"). Borrowed slices.
pub const Loc = struct {
    path: []const u8,
    inner: ?[]const u8 = null,
    password: ?[]const u8 = null,
    parents: []const ParentArc = &.{},
};

/// A Loc that owns its strings (history entries, the current place, a pending open).
pub const Saved = struct {
    arena: std.heap.ArenaAllocator,
    loc: Loc,

    pub fn init(gpa: Allocator, l: Loc) !Saved {
        var s: Saved = .{ .arena = .init(gpa), .loc = undefined };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        const parents = try a.alloc(ParentArc, l.parents.len);
        for (l.parents, parents) |p, *q| q.* = .{
            .source = try a.dupe(u8, p.source),
            .password = if (p.password) |x| try a.dupe(u8, x) else null,
            .cur = try a.dupe(u8, p.cur),
        };
        s.loc = .{
            .path = try a.dupe(u8, l.path),
            .inner = if (l.inner) |x| try a.dupe(u8, x) else null,
            .password = if (l.password) |x| try a.dupe(u8, x) else null,
            .parents = parents,
        };
        return s;
    }

    pub fn deinit(s: *Saved) void {
        s.arena.deinit();
    }
};

pub const Col = enum { name, size, @"packed", type, modified, crc, path };

/// MainForm.Row. `entry` = position in the archive's items (archived files); folders in an archive and ".."
/// have none. Strings live in the row arena or the archive's arena.
pub const Row = struct {
    name: []const u8,
    folder: bool,
    up: bool = false,
    /// -1 = blank
    size: i64 = -1,
    @"packed": i64 = -1,
    /// FILETIME ticks (UTC), 0 = none
    time: u64 = 0,
    /// Flat view: the entry's folder, with backslashes
    path: []const u8 = "",
    entry: ?u32 = null,
    type: []const u8 = "",
    selected: bool = false,
};

/// error.NotFound / error.NeedOpen (see `want`), anything the engine or the allocator raises.
pub const Error = anyerror;

/// What the window has to do for an activated row that the model cannot do itself.
pub const Action = union(enum) {
    none,
    /// Open in its own app (Process.Start). The path lives until the next fill.
    shell: []const u8,
    /// ToTemp: extract entry `index` to a temp dir first, then `afterTemp(dir, rel, as_archive)`.
    extract: struct { index: u32, rel: []const u8, as_archive: bool },
};

pub const Model = struct {
    gpa: Allocator,
    io: Io,
    a: ?*engine.Archive = null,
    /// The folder on disk; in an archive, the folder the (outermost) archive is in. gpa-owned.
    dir: []u8,
    /// The folder inside the archive: "" or "sub/deeper/". gpa-owned.
    cur: []u8,
    /// Per open archive: normalized entry names (Engine.Norm), the parent chain.
    arc_arena: std.heap.ArenaAllocator,
    names: []const []const u8 = &.{},
    parents: []const ParentArc = &.{},
    encrypted: bool = false,
    has_packed: bool = false,
    /// MainForm.Editable: edits go to the archive file itself (not a nested temp copy, a format 7z.dll rewrites).
    editable: bool = false,
    /// Here(), kept current.
    place: Saved,
    back: std.ArrayList(Saved) = .empty,
    fwd: std.ArrayList(Saved) = .empty,
    rows: std.ArrayList(Row) = .empty,
    row_arena: std.heap.ArenaAllocator,
    cols: []const Col = &disk_cols,
    sort: Col = .name,
    ascending: bool = true,
    /// Settings.FlatView (main_window persists it).
    flat: bool = false,
    /// The focused row (keyboard focus / the row F2 and Enter act on).
    focus: ?usize = null,
    /// The fill selected `select`: the window scrolls the focused row into view once.
    scroll: bool = false,
    /// Bumped on every fill / archive change: the window re-syncs the tree and the watcher.
    version: u32 = 0,
    /// Status bar text set by an action (report saved, deleted ...) until the selection changes. gpa-owned.
    message: ?[]u8 = null,
    /// error.NeedOpen / error.NotFound: the target that could not be shown, its select and record.
    want: ?Want = null,

    /// `status`: the status line once it is shown (an edit's "Deleted 3 files"), in saved's arena.
    pub const Want = struct { saved: Saved, select: ?[]u8, record: bool, status: ?[]const u8 = null };

    pub const disk_cols = [_]Col{ .name, .size, .type, .modified };
    pub const arc_cols = [_]Col{ .name, .size, .@"packed", .type, .modified, .crc };
    pub const flat_cols = [_]Col{ .name, .size, .@"packed", .type, .modified, .crc, .path };

    /// The window starts nowhere: `dir` (Documents / LastFolder) without a fill; call go() next.
    pub fn init(gpa: Allocator, io: Io, dir: []const u8) !Model {
        const d = try gpa.dupe(u8, dir);
        errdefer gpa.free(d);
        var place = try Saved.init(gpa, .{ .path = d });
        errdefer place.deinit();
        return .{
            .gpa = gpa,
            .io = io,
            .dir = d,
            .cur = try gpa.alloc(u8, 0),
            .arc_arena = .init(gpa),
            .row_arena = .init(gpa),
            .place = place,
        };
    }

    pub fn deinit(m: *Model) void {
        m.closeArchive();
        m.arc_arena.deinit();
        m.row_arena.deinit();
        m.rows.deinit(m.gpa);
        for (m.back.items) |*s| s.deinit();
        for (m.fwd.items) |*s| s.deinit();
        m.back.deinit(m.gpa);
        m.fwd.deinit(m.gpa);
        m.place.deinit();
        m.clearWant();
        m.setMessage(null);
        m.gpa.free(m.dir);
        m.gpa.free(m.cur);
    }

    // ---- locations ---------------------------------------------------------------------------------------

    pub fn inArchive(m: *const Model) bool {
        return m.a != null;
    }

    /// Here()
    pub fn here(m: *const Model) Loc {
        return m.place.loc;
    }

    fn current(m: *const Model) Loc {
        const a = m.a orelse return .{ .path = m.dir };
        return .{ .path = a.source, .inner = m.cur, .password = a.password, .parents = m.parents };
    }

    fn same(x: Loc, y: Loc) bool {
        if (!engine.samePath(x.path, y.path)) return false;
        if (x.inner == null or y.inner == null) return x.inner == null and y.inner == null;
        return std.mem.eql(u8, x.inner.?, y.inner.?);
    }

    pub fn go(m: *Model, to: Loc, select: ?[]const u8, record: bool) Error!void {
        return m.goWith(to, null, select, record);
    }

    /// MainForm.Go: shows `to`. An archive that is not the open one needs `opened` (from Dialogs.openArchive; taken
    /// over, also on failure), else error.NeedOpen. Nothing changes on an error.
    pub fn goWith(m: *Model, to: Loc, opened: ?*engine.Archive, select: ?[]const u8, record: bool) Error!void {
        var t = Saved.init(m.gpa, to) catch |e| {
            if (opened) |a| a.close();
            return e;
        };
        defer t.deinit();
        const sel: ?[]const u8 = if (select) |s| try t.arena.allocator().dupe(u8, s) else null;
        var l = t.loc;
        if (l.inner == null and opened != null) l.inner = "";
        if (l.inner == null) {
            if (!engine.dirExists(l.path)) {
                if (!engine.fileExists(l.path)) {
                    try m.setWant(l, sel, record);
                    return error.NotFound;
                }
                l.inner = "";
            }
        }
        if (l.inner == null) {
            const full = try engine.fullPath(m.gpa, l.path);
            m.closeArchive();
            m.gpa.free(m.dir);
            m.dir = full;
            try m.setCur("");
        } else {
            if (opened) |a| {
                try m.adopt(a, l);
            } else if (m.a == null or !engine.samePath(m.a.?.source, l.path)) {
                // never on the UI thread: Dialogs.openArchive opens it on a job (progress, Cancel), then goWith
                try m.setWant(l, sel, record);
                return error.NeedOpen;
            }
            const inner = l.inner.?;
            var cur: []const u8 = if (inner.len == 0 or std.mem.endsWith(u8, inner, "/")) inner else try std.mem.concat(t.arena.allocator(), u8, &.{ inner, "/" });
            // An edit (or a stale favorite) took the folder away: the nearest parent still there.
            while (cur.len > 0 and !m.hasUnder(cur)) cur = parentOf(cur);
            try m.setCur(cur);
        }
        var next = try Saved.init(m.gpa, m.current());
        var old = m.place;
        m.place = next;
        if (record and !same(old.loc, next.loc)) {
            m.back.append(m.gpa, old) catch old.deinit();
            for (m.fwd.items) |*s| s.deinit();
            m.fwd.clearRetainingCapacity();
        } else old.deinit();
        next = undefined;
        try m.fill(false, sel);
    }

    fn setCur(m: *Model, cur: []const u8) !void {
        const c = try m.gpa.dupe(u8, cur);
        m.gpa.free(m.cur);
        m.cur = c;
    }

    fn setWant(m: *Model, l: Loc, select: ?[]const u8, record: bool) !void {
        m.clearWant();
        var s = try Saved.init(m.gpa, l);
        errdefer s.deinit();
        const sel = if (select) |x| try s.arena.allocator().dupe(u8, x) else null;
        m.want = .{ .saved = s, .select = sel, .record = record };
    }

    pub fn clearWant(m: *Model) void {
        if (m.want) |*x| x.saved.deinit();
        m.want = null;
    }

    /// Takes over `a` as the open archive (closing the one before) for location `l` (its parent chain).
    fn adopt(m: *Model, a: *engine.Archive, l: Loc) !void {
        m.closeArchive();
        m.a = a;
        const ar = m.arc_arena.allocator();
        const parents = try ar.alloc(ParentArc, l.parents.len);
        for (l.parents, parents) |p, *q| q.* = .{
            .source = try ar.dupe(u8, p.source),
            .password = if (p.password) |x| try ar.dupe(u8, x) else null,
            .cur = try ar.dupe(u8, p.cur),
        };
        m.parents = parents;
        const outer = if (parents.len > 0) parents[0].source else a.source;
        if (pw.directoryName(outer)) |d| if (engine.fullPath(m.gpa, d)) |full| {
            m.gpa.free(m.dir);
            m.dir = full;
        } else |_| {};
        const items = a.items();
        const names = try ar.alloc([]const u8, items.len);
        m.encrypted = a.password != null;
        m.has_packed = false;
        for (items, names) |it, *n| {
            n.* = try engine.norm(ar, it.path);
            if (it.encrypted) m.encrypted = true;
            if (it.packed_size != null) m.has_packed = true;
        }
        m.names = names;
        m.editable = parents.len == 0 and engine.canDelete(m.io, a);
        m.version +%= 1;
    }

    /// The edits (Dialogs.deleteEntries / renameEntry / addToArchive) consume the archive: forget it without
    /// closing it (.detach_archive). A .reopen follows.
    pub fn detach(m: *Model) void {
        m.a = null;
        m.resetArchiveState();
        m.rows.clearRetainingCapacity();
        _ = m.row_arena.reset(.retain_capacity);
        m.focus = null;
        m.version +%= 1;
    }

    /// EnsurePassword's new instance replaces the open one (.replace_archive): same entries, now with bodies.
    pub fn replace(m: *Model, old: *engine.Archive, new: *engine.Archive) void {
        if (m.a != old) return new.close(); // ponytail: not ours any more (an edit detached it): drop the copy
        old.close();
        m.a = new;
        m.encrypted = m.encrypted or new.password != null;
        m.version +%= 1;
        var p = Saved.init(m.gpa, m.current()) catch return;
        m.place.deinit();
        m.place = p;
        p = undefined;
    }

    fn closeArchive(m: *Model) void {
        if (m.a) |a| a.close();
        m.a = null;
        m.resetArchiveState();
    }

    fn resetArchiveState(m: *Model) void {
        _ = m.arc_arena.reset(.retain_capacity);
        m.names = &.{};
        m.parents = &.{};
        m.encrypted = false;
        m.has_packed = false;
        m.editable = false;
    }

    /// Some entry is `cur` or under it ("a/b/").
    fn hasUnder(m: *const Model, cur: []const u8) bool {
        for (m.names) |n| {
            if (n.len >= cur.len) {
                if (eqlI(n[0..cur.len], cur)) return true;
            } else if (n.len + 1 == cur.len and eqlI(n, cur[0..n.len])) return true;
        }
        return false;
    }

    /// From Explorer (Program) and the Open dialog: a new place, Back returns to the old one. A folder works too.
    pub fn openPath(m: *Model, path: []const u8) Error!void {
        const full = try engine.fullPath(m.gpa, path);
        defer m.gpa.free(full);
        return m.go(.{ .path = full, .inner = if (engine.dirExists(full)) null else "" }, null, true);
    }

    /// "..": up a folder; from an archive's root to the folder (or the archive) it came from.
    pub fn up(m: *Model) Error!void {
        if (m.a) |a| {
            if (m.cur.len > 0) {
                return m.go(.{ .path = a.source, .inner = parentOf(m.cur), .password = a.password, .parents = m.parents }, lastSegment(m.cur), true);
            }
            const name = pw.fileName(a.source);
            if (m.parents.len > 0) {
                const p = m.parents[m.parents.len - 1];
                return m.go(.{ .path = p.source, .inner = p.cur, .password = p.password, .parents = m.parents[0 .. m.parents.len - 1] }, name, true);
            }
            return m.go(.{ .path = m.dir }, name, true);
        }
        const parent = pw.directoryName(m.dir) orelse return;
        return m.go(.{ .path = parent }, pw.fileName(m.dir), true);
    }

    /// Ctrl+\: the archive's root, or the drive's.
    pub fn root(m: *Model) Error!void {
        if (m.a) |a| return m.go(.{ .path = a.source, .inner = "", .password = a.password, .parents = m.parents }, null, true);
        if (m.dir.len >= 3 and m.dir[1] == ':') return m.go(.{ .path = m.dir[0..3] }, null, true);
    }

    pub fn goBack(m: *Model) Error!void {
        return m.step(&m.back, &m.fwd);
    }

    pub fn goForward(m: *Model) Error!void {
        return m.step(&m.fwd, &m.back);
    }

    fn step(m: *Model, from: *std.ArrayList(Saved), to: *std.ArrayList(Saved)) Error!void {
        var loc = from.pop() orelse return;
        defer loc.deinit();
        var h = try Saved.init(m.gpa, m.here());
        m.go(loc.loc, null, false) catch |e| {
            // NeedOpen: the open finishes the step (goWith from the window), so here is remembered now
            if (e == error.NeedOpen) to.append(m.gpa, h) catch h.deinit() else h.deinit();
            return e;
        };
        to.append(m.gpa, h) catch h.deinit();
    }

    /// A path typed into the address bar: a folder, an archive, or a folder inside one (C:\a.zip\sub).
    pub fn goTyped(m: *Model, text: []const u8) Error!void {
        const gpa = m.gpa;
        const trimmed = std.mem.trim(u8, std.mem.trim(u8, text, " \t"), "\"");
        if (trimmed.len == 0) return;
        const expanded = try kit.win.expandEnv(gpa, trimmed);
        defer gpa.free(expanded);
        const path = engine.fullPath(gpa, expanded) catch {
            try m.setWant(.{ .path = text }, null, true);
            return error.NotFound;
        };
        defer gpa.free(path);
        if (engine.dirExists(path)) return m.go(.{ .path = path }, null, true);
        var p: ?[]const u8 = path;
        while (p) |q| {
            p = pw.directoryName(q);
            if (engine.fileExists(q)) {
                const rest = try gpa.dupe(u8, std.mem.trim(u8, path[q.len..], "\\"));
                defer gpa.free(rest);
                std.mem.replaceScalar(u8, rest, '\\', '/');
                return m.go(.{ .path = q, .inner = rest }, null, true);
            }
        }
        try m.setWant(.{ .path = text }, null, true);
        return error.NotFound;
    }

    // ---- listing -----------------------------------------------------------------------------------------

    /// MainForm.Fill. `keep`: a refresh of the same place (the selection stays); `select`: the row to select,
    /// focus and scroll to.
    pub fn fill(m: *Model, keep: bool, select: ?[]const u8) !void {
        var kept: std.ArrayList([]u8) = .empty;
        defer {
            for (kept.items) |s| m.gpa.free(s);
            kept.deinit(m.gpa);
        }
        if (keep) for (m.rows.items) |r| if (r.selected) try kept.append(m.gpa, try m.gpa.dupe(u8, r.name));
        m.rows.clearRetainingCapacity();
        _ = m.row_arena.reset(.retain_capacity);
        m.setMessage(null);
        if (m.a != null) try m.archiveRows() else try m.diskRows();
        m.cols = if (m.a == null) &disk_cols else if (m.flat) &flat_cols else &arc_cols;
        if (std.mem.findScalar(Col, m.cols, m.sort) == null) m.sort = .name;
        m.sortRows();
        m.focus = null;
        m.scroll = false;
        for (m.rows.items, 0..) |*r, i| {
            for (kept.items) |k| if (eqlI(k, r.name)) {
                r.selected = true;
            };
            if (select) |s| if (eqlI(r.name, s)) {
                r.selected = true;
                m.focus = i;
                m.scroll = true;
            };
        }
        if (m.focus == null and m.rows.items.len > 0) m.focus = 0;
        m.version +%= 1;
    }

    fn diskRows(m: *Model) !void {
        const ar = m.row_arena.allocator();
        if (pw.directoryName(m.dir) != null) try m.rows.append(m.gpa, .{ .name = "..", .folder = true, .up = true });
        const pattern = try kit.win.toW(ar, try std.mem.concat(ar, u8, &.{ std.mem.trimEnd(u8, m.dir, "\\"), "\\*" }));
        var fd: w.WIN32_FIND_DATAW = undefined;
        const h = w.FindFirstFileExW(pattern.ptr, w.FindExInfoBasic, &fd, w.FindExSearchNameMatch, null, w.FIND_FIRST_EX_LARGE_FETCH);
        if (h == w.INVALID_HANDLE_VALUE) {
            const e = w.GetLastError();
            if (e != w.ERROR_FILE_NOT_FOUND) m.setMessage(engine.friendly(if (e == w.ERROR_ACCESS_DENIED) error.AccessDenied else error.Unexpected, null));
            return;
        }
        defer _ = w.FindClose(h);
        while (true) {
            const name = try kit.win.fromWZ(ar, @ptrCast(&fd.cFileName));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const folder = fd.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY != 0;
                try m.rows.append(m.gpa, .{
                    .name = name,
                    .folder = folder,
                    .size = if (folder) -1 else @intCast(@as(u64, fd.nFileSizeHigh) << 32 | fd.nFileSizeLow),
                    .time = @as(u64, fd.ftLastWriteTime.dwHighDateTime) << 32 | fd.ftLastWriteTime.dwLowDateTime,
                    .type = shell.typeName(name, folder),
                });
            }
            if (w.FindNextFileW(h, &fd) == 0) break;
        }
    }

    fn archiveRows(m: *Model) !void {
        const a = m.a.?;
        const ar = m.row_arena.allocator();
        try m.rows.append(m.gpa, .{ .name = "..", .folder = true, .up = true });
        const Agg = struct { size: i64 = 0, @"packed": i64 = 0, time: u64 = 0 };
        var folders: std.array_hash_map.String(Agg) = .empty; // key: upper-cased name -> first spelling below
        var spelling: std.ArrayList([]const u8) = .empty;
        for (a.items(), m.names) |it, n| {
            if (n.len == 0 or n.len < m.cur.len or !eqlI(n[0..m.cur.len], m.cur)) continue;
            const rest = n[m.cur.len..];
            if (rest.len == 0) continue;
            const packed_size: i64 = if (it.packed_size) |p| @intCast(p) else -1;
            const slash = std.mem.findScalar(u8, rest, '/');
            if (m.flat) {
                if (!it.is_dir) {
                    const last = std.mem.findScalarLast(u8, rest, '/');
                    const name = if (last) |i| rest[i + 1 ..] else rest;
                    var dir: []const u8 = "";
                    if (last) |i| {
                        const d = try ar.dupe(u8, rest[0..i]);
                        std.mem.replaceScalar(u8, d, '/', '\\');
                        dir = d;
                    }
                    try m.rows.append(m.gpa, .{ .name = name, .folder = false, .size = @intCast(it.size), .@"packed" = packed_size, .time = it.mtime, .path = dir, .entry = it.index, .type = shell.typeName(name, false) });
                }
                continue;
            }
            if (slash != null or it.is_dir) {
                const name = if (slash) |i| rest[0..i] else rest;
                const g = try folders.getOrPut(ar, try shell.upperKey(ar, name));
                if (!g.found_existing) {
                    g.value_ptr.* = .{};
                    try spelling.append(ar, name);
                }
                if (!it.is_dir) {
                    g.value_ptr.size += @intCast(it.size);
                    g.value_ptr.@"packed" += @max(0, packed_size);
                }
                if (slash == null) g.value_ptr.time = it.mtime; // the folder's own entry carries its time
            } else try m.rows.append(m.gpa, .{ .name = rest, .folder = false, .size = @intCast(it.size), .@"packed" = packed_size, .time = it.mtime, .entry = it.index, .type = shell.typeName(rest, false) });
        }
        for (folders.values(), spelling.items) |g, name| try m.rows.append(m.gpa, .{
            .name = name,
            .folder = true,
            .size = g.size,
            .@"packed" = if (m.has_packed) g.@"packed" else -1,
            .time = g.time,
            .type = shell.typeName(name, true),
        });
    }

    /// Comparer: ".." on top, folders first, then the column (the name breaks ties); `ascending` flips the rest.
    fn lessThan(m: *const Model, x: Row, y: Row) bool {
        if (x.up != y.up) return x.up;
        if (x.folder != y.folder) return x.folder;
        var r: std.math.Order = switch (m.sort) {
            .size => std.math.order(x.size, y.size),
            .@"packed" => std.math.order(x.@"packed", y.@"packed"),
            .modified => std.math.order(x.time, y.time),
            .type => shell.compareText(x.type, y.type),
            .path => shell.compareText(x.path, y.path),
            .crc => std.math.order(m.crcOf(x) orelse 0, m.crcOf(y) orelse 0),
            .name => shell.compareText(x.name, y.name),
        };
        if (r == .eq and m.sort != .name) r = shell.compareText(x.name, y.name);
        return if (m.ascending) r == .lt else r == .gt;
    }

    pub fn sortRows(m: *Model) void {
        std.mem.sort(Row, m.rows.items, m, lessThan);
    }

    /// SortBy: the column header (the same column again flips the order).
    pub fn sortBy(m: *Model, col: Col, ascending: bool) void {
        m.sort = col;
        m.ascending = ascending;
        var focused: ?[]const u8 = if (m.focus) |f| if (f < m.rows.items.len) m.rows.items[f].name else null else null;
        m.sortRows();
        if (focused) |n| for (m.rows.items, 0..) |r, i| if (r.name.ptr == n.ptr) {
            m.focus = i;
            focused = null;
            break;
        };
    }

    pub fn crcOf(m: *const Model, r: Row) ?u32 {
        const e = r.entry orelse return null;
        const c = m.a.?.items()[e].crc orelse return null;
        return if (c == 0) null else c;
    }

    /// One cell as the list shows it.
    pub fn cell(m: *const Model, buf: []u8, r: Row, c: Col) []const u8 {
        return switch (c) {
            .name => r.name,
            .size => if (r.size < 0) "" else groupText(buf, @intCast(r.size)),
            .@"packed" => if (r.@"packed" < 0 or r.up) "" else groupText(buf, @intCast(r.@"packed")),
            .type => if (r.up) "" else r.type,
            .modified => shell.timeText(buf, r.time),
            .crc => if (m.crcOf(r)) |x| std.mem.print(buf, "{X:0>8}", .{x}) catch "" else "",
            .path => r.path,
        };
    }

    // ---- texts ------------------------------------------------------------------------------------------

    pub fn setMessage(m: *Model, text: ?[]const u8) void {
        if (m.message) |s| m.gpa.free(s);
        m.message = if (text) |t| m.gpa.dupe(u8, t) catch null else null;
    }

    /// status line: the totals of the list, or of the selection when there is one.
    pub fn statusText(m: *const Model, buf: []u8) []const u8 {
        if (m.message) |s| return s;
        var any = false;
        for (m.rows.items) |r| if (r.selected and !r.up) {
            any = true;
        };
        var folders: u64 = 0;
        var files: u64 = 0;
        var total: u64 = 0;
        for (m.rows.items) |r| {
            if (r.up or (any and !r.selected)) continue;
            if (r.folder) folders += 1 else files += 1;
            total += @intCast(@max(0, r.size));
        }
        var parts: [256]u8 = undefined;
        var pw_: std.Io.Writer = .fixed(&parts);
        var b: [64]u8 = undefined;
        if (folders > 0) pw_.writeAll(S.foldersN(&b, folders)) catch {};
        if (files > 0 or folders == 0) {
            if (folders > 0) pw_.writeAll(", ") catch {};
            pw_.writeAll(S.filesN(&b, files)) catch {};
        }
        if (total > 0 or files > 0) {
            pw_.writeAll(", ") catch {};
            pw_.writeAll(S.bytes(&b, total)) catch {};
        }
        return S.fillZ(buf, if (any) S.chosenFmt.get() else S.totalFmt.get(), .{pw_.buffered()});
    }

    /// The address bar: the folder, or "name.zip\sub - ZIP archive, unpacked size N bytes".
    pub fn addressText(m: *const Model, buf: []u8) []const u8 {
        const a = m.a orelse return std.mem.print(buf, "{s}", .{m.dir}) catch m.dir;
        var total: u64 = 0;
        for (a.items()) |it| if (!it.is_dir) {
            total += it.size;
        };
        var where_buf: [1024]u8 = undefined;
        var b: [64]u8 = undefined;
        var fb: [32]u8 = undefined;
        return S.fillZ(buf, S.archiveAddressFmt.get(), .{ m.where(&where_buf), formatName(&fb, a), S.bytes(&b, total) });
    }

    /// "name.zip\sub\dir" (the address, the favorite's default name).
    pub fn where(m: *const Model, buf: []u8) []const u8 {
        const a = m.a orelse return m.dir;
        var o: std.Io.Writer = .fixed(buf);
        o.writeAll(a.display()) catch {};
        if (m.cur.len > 0) {
            o.writeAll("\\") catch {};
            for (std.mem.trimEnd(u8, m.cur, "/")) |c| o.writeByte(if (c == '/') '\\' else c) catch {};
        }
        return o.buffered();
    }

    /// "<folder or archive> — MakePack" (the OS window title: it carries the open archive's name).
    pub fn titleText(m: *const Model, buf: []u8) []const u8 {
        const what = if (m.a) |a| a.display() else m.dir;
        return std.mem.print(buf, "{s} \u{2014} {s}", .{ what, S.app }) catch S.app;
    }

    // ---- items -------------------------------------------------------------------------------------------

    /// dir\name (a disk row's full path), in the row arena (lives until the next fill).
    pub fn diskPath(m: *Model, name: []const u8) ![]const u8 {
        return join(m.row_arena.allocator(), m.dir, name);
    }

    /// "cur/<flat dir/>name": a row's entry name inside the archive.
    pub fn entryName(m: *Model, ar: Allocator, r: Row) ![]u8 {
        const dir = try ar.dupe(u8, r.path);
        std.mem.replaceScalar(u8, dir, '\\', '/');
        return std.mem.concat(ar, u8, &.{ m.cur, dir, if (dir.len > 0) "/" else "", r.name });
    }

    /// Enter / double click: into a folder or an archive; anything else opens in its own app.
    pub fn activate(m: *Model, i: usize, as_archive: bool) Error!Action {
        if (i >= m.rows.items.len) return .none;
        const r = m.rows.items[i];
        if (r.up) {
            try m.up();
            return .none;
        }
        const a = m.a orelse {
            const path = try m.diskPath(r.name);
            if (r.folder) {
                try m.go(.{ .path = path }, null, true);
            } else if (as_archive or m.isArchiveFile(path)) {
                try m.go(.{ .path = path, .inner = "" }, null, true);
            } else return .{ .shell = path };
            return .none;
        };
        const e = r.entry orelse {
            const inner = try std.mem.concat(m.row_arena.allocator(), u8, &.{ m.cur, r.name, "/" });
            try m.go(.{ .path = a.source, .inner = inner, .password = a.password, .parents = m.parents }, null, true);
            return .none;
        };
        if (r.folder) return .none;
        return .{ .extract = .{ .index = e, .rel = m.names[e], .as_archive = as_archive } };
    }

    /// ToTemp's second half: `rel` reached `dir`; a nested archive opens here, anything else in its own app.
    pub fn afterTemp(m: *Model, dir: []const u8, rel: []const u8, as_archive: bool) Error!Action {
        const ar = m.row_arena.allocator();
        const r = try ar.dupe(u8, rel);
        std.mem.replaceScalar(u8, r, '/', '\\');
        const file = try join(ar, dir, r);
        if (!engine.fileExists(file)) return .none;
        if (as_archive or m.isArchiveFile(file)) {
            try m.openNested(file);
            return .none;
        }
        return .{ .shell = file };
    }

    fn openNested(m: *Model, file: []const u8) Error!void {
        const a = m.a orelse return;
        const chain = try m.row_arena.allocator().alloc(ParentArc, m.parents.len + 1);
        @memcpy(chain[0..m.parents.len], m.parents);
        chain[m.parents.len] = .{ .source = a.source, .password = a.password, .cur = m.cur };
        return m.go(.{ .path = file, .inner = "", .parents = chain }, null, true);
    }

    /// The selftest's ToTemp (no progress window): entry `index` into a fresh engine temp dir (gpa-owned path).
    pub fn toTempSync(m: *Model, index: u32) ![]u8 {
        const dir = try engine.newTempDir(m.gpa, m.io);
        errdefer m.gpa.free(dir);
        try engine.extract(m.gpa, m.io, m.a.?, dir, &.{index}, .Overwrite, .none, .always_overwrite, .Never, .{}, null);
        return dir;
    }

    /// What OtherArc would open inside itself: one of our archive types that really is an archive (not a .docx).
    pub fn isArchiveFile(m: *const Model, path: []const u8) bool {
        const ext = std.mem.trimStart(u8, pw.extension(path), ".");
        return types.isArchiveExt(ext) and engine.looksLikeArchive(m.io, path);
    }

    // ---- selection ---------------------------------------------------------------------------------------

    pub fn anySelected(m: *const Model) bool {
        for (m.rows.items) |r| if (r.selected and !r.up) return true;
        return false;
    }

    pub fn selectedCount(m: *const Model) usize {
        var n: usize = 0;
        for (m.rows.items) |r| n += @intFromBool(r.selected and !r.up);
        return n;
    }

    /// The one selected row; with several, the focused one among them (DoView).
    pub fn oneSelected(m: *const Model) ?usize {
        var found: ?usize = null;
        var n: usize = 0;
        for (m.rows.items, 0..) |r, i| if (r.selected and !r.up) {
            found = i;
            n += 1;
        };
        if (n == 1) return found;
        if (m.focus) |f| if (f < m.rows.items.len and m.rows.items[f].selected and !m.rows.items[f].up) return f;
        return null;
    }

    /// Disk mode: full paths of the selection (`ar`-owned).
    pub fn selectedPaths(m: *Model, ar: Allocator, files_only: bool) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (m.rows.items) |r| if (r.selected and !r.up and !(files_only and r.folder)) try list.append(ar, try join(ar, m.dir, r.name));
        return list.toOwnedSlice(ar);
    }

    /// Archive mode: the entry indices to act on (a selected folder = every entry under it); null when nothing
    /// is selected (= the whole archive).
    pub fn selected(m: *Model, ar: Allocator) !?[]u32 {
        _ = m.a orelse return null;
        if (!m.anySelected()) return null;
        var set = try std.DynamicBitSetUnmanaged.initEmpty(ar, m.names.len);
        var folders: std.ArrayList([]const u8) = .empty;
        for (m.rows.items) |r| if (r.selected and !r.up) {
            if (r.entry) |e| set.set(e) else try folders.append(ar, try std.mem.concat(ar, u8, &.{ m.cur, r.name, "/" }));
        };
        if (folders.items.len > 0) for (m.names, 0..) |n, i| {
            for (folders.items) |p| {
                if ((n.len >= p.len and eqlI(n[0..p.len], p)) or (n.len + 1 == p.len and eqlI(n, p[0..n.len]))) {
                    set.set(i);
                    break;
                }
            }
        };
        var out: std.ArrayList(u32) = .empty;
        var it = set.iterator(.{});
        while (it.next()) |i| try out.append(ar, m.a.?.items()[i].index);
        return try out.toOwnedSlice(ar);
    }

    pub fn selectAll(m: *Model) void {
        for (m.rows.items) |*r| r.selected = !r.up;
        m.setMessage(null);
    }

    pub fn invert(m: *Model) void {
        for (m.rows.items) |*r| r.selected = !r.selected and !r.up;
        m.setMessage(null);
    }

    /// Num+ / Num-: (de)select the items whose name matches the mask (several with ';').
    pub fn selectGroup(m: *Model, mask: []const u8, on: bool) void {
        for (m.rows.items) |*r| if (!r.up and matches(r.name, mask)) {
            r.selected = on;
        };
        m.setMessage(null);
    }

    /// F2's checks (MainForm.DoRename): a name Windows can hold, not taken by a sibling (case-only renames pass).
    pub fn checkName(m: *const Model, old: []const u8, name: []const u8) error{ BadName, NameTaken }!void {
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.findAny(u8, name, "/\\:*?\"<>|") != null)
            return error.BadName;
        for (m.rows.items) |r| if (eqlI(r.name, name) and !eqlI(r.name, old)) return error.NameTaken;
    }

    /// NewFolder: "New folder", "New folder (2)", ... created on disk; its row is selected and focused.
    pub fn newFolder(m: *Model) !?usize {
        if (m.a != null) return null;
        const ar = m.row_arena.allocator();
        var name: []const u8 = S.newFolderName.get();
        var n: u32 = 2;
        while (true) : (n += 1) {
            const p = try join(ar, m.dir, name);
            if (!engine.dirExists(p) and !engine.fileExists(p)) {
                try shell.makeDir(m.gpa, p);
                break;
            }
            name = try ar.print("{s} ({d})", .{ S.newFolderName.get(), n });
        }
        const keep = try m.gpa.dupe(u8, name);
        defer m.gpa.free(keep);
        try m.fill(false, keep);
        return m.focus;
    }
};

// ---- helpers ----------------------------------------------------------------------------------------------

/// "a/b/" -> "a/", "a/" -> "".
pub fn parentOf(folder: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, folder, "/");
    const i = std.mem.findScalarLast(u8, t, '/') orelse return "";
    return folder[0 .. i + 1];
}

/// "a/b/" -> "b".
pub fn lastSegment(folder: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, folder, "/");
    const i = std.mem.findScalarLast(u8, t, '/') orelse return t;
    return t[i + 1 ..];
}

/// Path.Combine for a folder (that may be a root "C:\") and a name.
pub fn join(ar: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.mem.concat(ar, u8, &.{ dir, if (std.mem.endsWith(u8, dir, "\\")) "" else "\\", name });
}

/// "7z", else the format's name upper-cased ("ZIP", "TAR").
pub fn formatName(buf: *[32]u8, a: *const engine.Archive) []const u8 {
    if (a.x.props.format == .SevenZip) return "7z";
    const n = a.x.props.format_name[0..@min(a.x.props.format_name.len, buf.len)];
    return std.ascii.upperString(buf[0..n.len], n);
}

/// 1,234,567 (the culture's group separator).
fn groupText(buf: []u8, n: u64) []const u8 {
    var g: [40]u8 = undefined;
    const s = S.group(&g, n);
    const len = @min(s.len, buf.len);
    @memcpy(buf[0..len], s[0..len]);
    return buf[0..len];
}

/// FindForm.Matches: Win32 masks ('*', '?', "*.*" = all), several with ';', case-insensitive; no mask = all.
pub fn matches(name: []const u8, masks: []const u8) bool {
    var any = false;
    var it = std.mem.splitScalar(u8, masks, ';');
    while (it.next()) |raw| {
        const mask = std.mem.trim(u8, raw, " \t");
        if (mask.len == 0) continue;
        any = true;
        if (std.mem.eql(u8, mask, "*.*") or std.mem.eql(u8, mask, "*")) return true;
        // "*." = no extension (Win32)
        if (std.mem.endsWith(u8, mask, ".") and std.mem.findScalar(u8, name, '.') == null and glob(name, mask[0 .. mask.len - 1])) return true;
        if (glob(name, mask)) return true;
    }
    return !any;
}

// ponytail: ASCII case folding over UTF-8 bytes ('?' = one byte); Cyrillic names match exactly-cased masks only.
fn glob(name: []const u8, mask: []const u8) bool {
    var n: usize = 0;
    var m: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (m < mask.len and mask[m] == '*') {
            star = m;
            m += 1;
            mark = n;
        } else if (m < mask.len and (mask[m] == '?' or std.ascii.toLower(mask[m]) == std.ascii.toLower(name[n]))) {
            m += 1;
            n += 1;
        } else if (star) |s| {
            m = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (m < mask.len and mask[m] == '*') m += 1;
    return m == mask.len;
}

test "masks, parentOf, lastSegment" {
    const t = std.testing;
    try t.expect(matches("a.cs", "*.cs") and !matches("a.csv", "*.cs") and matches("A.CS", "*.cs"));
    try t.expect(matches("x.md", "*.txt;*.md") and matches("x", "*.*") and matches("x", "") and matches("readme", "*."));
    try t.expect(!matches("a.txt", "*.") and matches("ab", "a?") and !matches("abc", "a?"));
    try t.expectEqualStrings("a/", parentOf("a/b/"));
    try t.expectEqualStrings("", parentOf("a/"));
    try t.expectEqualStrings("b", lastSegment("a/b/"));
    try t.expectEqualStrings("a", lastSegment("a/"));
}
