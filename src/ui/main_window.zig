//! MP-G1: the main window (legacy/src/MakePack/MainForm.cs + Shell.cs in git history; docs/ICONS-NEEDED.md). Owner: MP-G1 = this file + src/ui/mw_*.zig.
//! main.zig owns at most one MainWindow (Program._main). Contract with main.zig:
//!   init(ctx, path)  (in place) Program.OpenMain's `new MainForm(archive)`: path null = LastFolder / home.
//!   open(path)       a forwarded "<archive>" while the window exists (MainForm.OpenArchive). Deferred by the
//!                    window itself while ctx.dialogs.modal() is true.
//!   handle(req)      one request from the dialogs (ctx.zig Request), at the start of the frame, before draw;
//!                    takes ownership (req.deinit(ctx.gpa) when done).
//!   draw()           every frame, before Dialogs.draw; false = the window closed itself (Exit, Alt+F4 handled
//!                    in-app): main.zig deinits it. Sets the OS window title (must contain the open archive's name).
//!   filesDropped     drag-in (kit files_dropped) when the dialogs did not take the drop.
//!   deinit()         persists Window/Maximized/Tree/ListMode/... (settings.commit), closes the archive.
//! The dialogs are reached through ctx.dialogs (src/ui/dialogs.zig documents every entry point and the rules about
//! the borrowed archive, modal(), .detach_archive / .replace_archive / .release_archive).
//!
//! Layout (classic archiver): menu, 32 px toolbar with the label under each picture, Up + address bar, the folder tree
//! (Ctrl+T) | the list, the status bar (drive, lock, totals). State lives in mw_model.zig (also driven by the
//! selftest); shell helpers in mw_shell.zig, drag-out in mw_drag.zig; every picture is the kit's Carbon Mint set.
//! Automation ids (MakeKit K8): menus ###mfile..###mhelp, items ###m_<cmd>, toolbar ###tb_<name>, ###up, ##address,
//! ##address_drop, rows "<name>###r", tree nodes "###t<key>", the rename box ##rename, the status "###status",
//! the main ImGui window "<title>###main" (its name carries the title, as the OS window does).
const std = @import("std");
const kit = @import("kit");
const C = @import("ctx.zig");
const model = @import("mw_model.zig");
const shell = @import("mw_shell.zig");
const drag = @import("mw_drag.zig");
const pw = @import("../platform/platform_win.zig");

const Ctx = C.Ctx;
const S = C.S;
const engine = C.engine;
const settings = C.settings;
const im = kit.im;
const w = kit.w;
const Model = model.Model;
const Row = model.Row;
const Col = model.Col;
const Allocator = std.mem.Allocator;
const types = @import("../core/types.zig");
const eqlI = types.eqlIgnoreCase;

/// Application.ProductVersion: build.zig.zon's .version.
const version = @import("updates.zig").version;

/// What an asynchronous answer (a ctx.Token) is for.
const Pending = union(enum) {
    /// Dialogs.openArchive for Go(): then goWith(want, archive).
    go: Model.Want,
    /// ToTemp for OpenItem: the entry's name and Ctrl+PgDn.
    open_temp: struct { rel: []u8, as_archive: bool },
    /// ToTemp for Ctrl+C: the entries' names relative to the temp dir (backslashes).
    copy_files: [][]u8,
    /// Ready() before a drag-out.
    drag,
    /// Ready() before Test on the open archive.
    test_arc,
    /// NameForm.Line for Select group (true) / Deselect group (false).
    mask: bool,
    /// NameForm.Line for Add to favorites: where the favorite points.
    favorite: struct { path: []u8, inner: ?[]u8 },

    fn deinit(p: *Pending, gpa: Allocator) void {
        switch (p.*) {
            .go => |*x| x.saved.deinit(),
            .open_temp => |x| gpa.free(x.rel),
            .copy_files => |l| {
                for (l) |s| gpa.free(s);
                gpa.free(l);
            },
            .favorite => |f| {
                gpa.free(f.path);
                if (f.inner) |s| gpa.free(s);
            },
            .drag, .test_arc, .mask => {},
        }
    }
};

const After = union(enum) { activate: usize, rename };

/// The folder tree (Ctrl+T): drives -> folders, loaded lazily; in an archive, the archive's own folders.
const Node = struct {
    label: []const u8,
    /// disk: the full path; archive: "a/b/" ("" = the archive's root)
    key: []const u8,
    loaded: bool,
    drive: bool = false,
    children: std.ArrayList(Node) = .empty,
};

const Tree = struct {
    arena: std.heap.ArenaAllocator,
    roots: std.ArrayList(Node) = .empty,
    /// The archive the roots were built from (null = drives).
    arc: ?*engine.Archive = null,
    built: bool = false,
    /// Open the way to the current place and scroll to it (after a navigation).
    sync: bool = true,
    ver: u32 = std.math.maxInt(u32),
};

pub const MainWindow = struct {
    ctx: *Ctx,
    m: Model,
    watcher: shell.Watcher = .{},
    watched: ?[]u8 = null,
    tree: Tree,
    pending: std.AutoHashMapUnmanaged(C.Token, Pending) = .empty,
    next_token: C.Token = 1,
    /// open() while a modal dialog borrows the archive.
    deferred: ?[]u8 = null,
    address: [2048:0]u8 = @splat(0),
    address_active: bool = false,
    open_drives: bool = false,
    /// F2: the row being renamed, its text box.
    edit: ?usize = null,
    edit_buf: [1024:0]u8 = @splat(0),
    edit_old: ?[]u8 = null,
    edit_frames: u32 = 0,
    edit_cancel: bool = false,
    show_tree: bool = false,
    list_mode: bool = false,
    tree_w: f32 = 240,
    focus_list: bool = true,
    main_focused: bool = false,
    closed: bool = false,
    mask: []u8,
    /// Our own drag-out is in flight (or just ended): a drop back onto us is ignored.
    dragging: bool = false,
    ignore_drops_until: u64 = 0,
    drag_req: bool = false,
    /// Row actions that refill the list run after the frame's drawing (the list is being iterated then).
    after: ?After = null,
    sorted_ver: u32 = std.math.maxInt(u32),
    /// The address bar took this frame's Enter.
    skip_keys: bool = false,
    title: [1024]u8 = undefined,
    title_len: usize = 0,
    bounds: ?[4]i32 = null,
    maximized: bool = false,

    /// In place (main.zig's Ui.mw): the window may hand out pointers to itself.
    pub fn init(mw: *MainWindow, ctx: *Ctx, path: ?[]const u8) void {
        const gpa = ctx.gpa;
        const s = settings.current();
        const docs_buf: ?[]u8 = kit.win.knownFolder(gpa, &w.FOLDERID_Documents) catch null;
        defer if (docs_buf) |d| gpa.free(d);
        const start: []const u8 = if (s.LastFolder) |l| (if (engine.dirExists(l)) l else docs_buf orelse "C:\\") else docs_buf orelse "C:\\";
        mw.* = .{
            .ctx = ctx,
            .m = Model.init(gpa, ctx.io, start) catch @panic("out of memory"),
            .tree = .{ .arena = .init(gpa) },
            .mask = gpa.dupe(u8, "*.*") catch @panic("out of memory"),
            .show_tree = s.Tree,
            .list_mode = s.ListMode,
            .tree_w = 240,
        };
        mw.m.flat = s.FlatView;
        mw.restoreLayout();
        var first: []const u8 = start;
        var full: ?[]u8 = null;
        defer if (full) |f| gpa.free(f);
        if (path) |p| {
            full = engine.fullPath(gpa, p) catch null;
            if (full) |f| first = if (engine.dirExists(f)) f else pw.directoryName(f) orelse start;
        }
        mw.m.go(.{ .path = first }, null, false) catch {
            mw.m.go(.{ .path = "C:\\" }, null, false) catch {};
        };
        mw.m.clearWant();
        if (full) |f| if (!engine.dirExists(f)) mw.nav(mw.m.go(.{ .path = f, .inner = "" }, null, false));
    }

    pub fn deinit(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        mw.saveLayout();
        mw.watcher.stop(gpa);
        if (mw.watched) |d| gpa.free(d);
        var it = mw.pending.valueIterator();
        while (it.next()) |p| p.deinit(gpa);
        mw.pending.deinit(gpa);
        if (mw.deferred) |d| gpa.free(d);
        if (mw.edit_old) |d| gpa.free(d);
        gpa.free(mw.mask);
        mw.tree.arena.deinit();
        mw.m.deinit();
        drag.deinit();
    }

    /// MainForm.OpenArchive (a forwarded archive or folder, the Open dialog).
    pub fn open(mw: *MainWindow, path: []const u8) void {
        if (mw.ctx.dialogs.modal()) {
            const d = mw.ctx.dupe(path) catch return;
            if (mw.deferred) |old| mw.ctx.gpa.free(old);
            mw.deferred = d;
            return;
        }
        mw.nav(mw.m.openPath(path));
        mw.focus_list = true;
    }

    pub fn handle(mw: *MainWindow, req: C.Request) void {
        const gpa = mw.ctx.gpa;
        defer req.deinit(gpa);
        switch (req) {
            .open_main => {},
            .open_path => |o| mw.nav(mw.m.go(.{ .path = o.path }, o.select, o.record)),
            .locate => |l| {
                if (l.inner) |inner| {
                    const slash = std.mem.findScalarLast(u8, inner, '/');
                    const folder = if (slash) |i| inner[0 .. i + 1] else "";
                    mw.nav(mw.m.go(.{ .path = l.path, .inner = folder }, if (slash) |i| inner[i + 1 ..] else inner, true));
                } else if (pw.directoryName(l.path)) |dir| mw.nav(mw.m.go(.{ .path = dir }, pw.fileName(l.path), true));
                mw.ctx.raise();
            },
            .refresh => mw.m.fill(true, null) catch {},
            .release_archive => if (mw.m.a != null) mw.nav(mw.m.go(.{ .path = mw.m.dir }, null, false)),
            .detach_archive => |a| if (mw.m.a == a) mw.m.detach(),
            .replace_archive => |r| mw.m.replace(r.old, r.new),
            .reopen => |o| {
                // Modify: Go(Loc(source, cur, password), select, record: false); when that fails, the folder.
                // The edit closed the archive, so it is opened again on a job (NeedOpen); its folder shows
                // meanwhile, which is also what stays when that open fails or is cancelled.
                mw.m.go(.{ .path = o.source, .inner = o.cur, .password = o.password }, o.select, false) catch |e| {
                    var want = mw.m.want;
                    mw.m.want = null;
                    mw.nav(mw.m.go(.{ .path = mw.m.dir }, null, false));
                    if (e != error.NeedOpen or want == null) {
                        if (want) |*x| x.saved.deinit();
                        return;
                    }
                    if (o.status) |s| want.?.status = want.?.saved.arena.allocator().dupe(u8, s) catch null;
                    mw.m.clearWant();
                    mw.m.want = want;
                    return mw.navError(e);
                };
                if (o.status) |s| mw.m.setMessage(s);
            },
            .opened => |o| {
                var p = mw.pending.fetchRemove(o.token) orelse return o.archive.close();
                if (p.value == .go) {
                    const want = p.value.go;
                    if (mw.m.goWith(want.saved.loc, o.archive, want.select, want.record)) {
                        if (want.status) |s| mw.m.setMessage(s);
                    } else |e| mw.navError(e);
                } else o.archive.close();
                p.value.deinit(gpa);
            },
            .ready => |t| {
                var p = mw.pending.fetchRemove(t) orelse return;
                defer p.value.deinit(gpa);
                switch (p.value) {
                    // A password prompt took the press: the user drags again.
                    .drag => if (w.GetAsyncKeyState(w.VK_LBUTTON) < 0) mw.dragArchive(),
                    // A new instance (the password) came as .replace_archive just before: m.a is it.
                    .test_arc => if (mw.m.a) |a| mw.ctx.dialogs.testArchive(a),
                    else => {},
                }
            },
            .temp_ready => |t| {
                var p = mw.pending.fetchRemove(t.token) orelse return;
                defer p.value.deinit(gpa);
                switch (p.value) {
                    .open_temp => |x| mw.act(mw.m.afterTemp(t.dir, x.rel, x.as_archive)),
                    .copy_files => |rels| {
                        var paths: std.ArrayList([]const u8) = .empty;
                        defer {
                            for (paths.items) |s| gpa.free(s);
                            paths.deinit(gpa);
                        }
                        for (rels) |r| paths.append(gpa, model.join(gpa, t.dir, r) catch continue) catch {};
                        // ponytail: the temp copy lives until MakePack exits; a paste after that finds nothing.
                        _ = shell.setFiles(gpa, mw.ctx.app.hwnd, paths.items);
                    },
                    else => {},
                }
            },
            .confirmed => {},
            .text => |t| {
                var p = mw.pending.fetchRemove(t.token) orelse return;
                defer p.value.deinit(gpa);
                switch (p.value) {
                    .mask => |on| {
                        const mask = std.mem.trim(u8, t.value, " \t");
                        if (mask.len == 0) return;
                        const copy = gpa.dupe(u8, mask) catch return;
                        gpa.free(mw.mask);
                        mw.mask = copy;
                        mw.m.selectGroup(mw.mask, on);
                        mw.focus_list = true;
                    },
                    .favorite => |f| mw.addFavorite(std.mem.trim(u8, t.value, " \t"), f.path, f.inner),
                    else => {},
                }
            },
            .status => |s| mw.m.setMessage(s),
            .settings_changed => {
                const s = settings.current();
                if (mw.m.flat != s.FlatView and mw.m.a != null) {
                    mw.m.flat = s.FlatView;
                    mw.m.fill(true, null) catch {};
                }
                mw.m.flat = s.FlatView;
            },
        }
    }

    /// Drag-in: into an open archive the files are added; on disk a dropped archive is opened and anything else
    /// goes to the New archive dialog (a drop = Add). Our own drag-out coming back is ignored.
    pub fn filesDropped(mw: *MainWindow, paths: []const []const u8, pos: im.ImVec2) void {
        _ = pos;
        if (paths.len == 0 or mw.dragging or w.GetTickCount64() < mw.ignore_drops_until or mw.ctx.dialogs.modal()) return;
        const d = mw.ctx.dialogs;
        if (mw.m.a) |a| return d.addToArchive(a, paths, mw.m.cur, mw.m.editable);
        if (paths.len == 1 and engine.fileExists(paths[0]) and engine.looksLikeArchive(mw.ctx.io, paths[0])) return mw.open(paths[0]);
        d.compress(paths, true);
    }

    // ---- frame -------------------------------------------------------------------------------------------

    pub fn draw(mw: *MainWindow) bool {
        if (mw.closed) return false;
        const modal = mw.ctx.dialogs.modal();
        if (!modal) if (mw.deferred) |p| {
            mw.deferred = null;
            mw.open(p);
            mw.ctx.gpa.free(p);
        };
        if (mw.watcher.take() and mw.m.a == null and mw.edit == null) mw.m.fill(true, null) catch {};
        mw.syncWatch();
        mw.syncTitle();

        const vp = im.ImGui_GetMainViewport();
        im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
        im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
        var nb: [1100]u8 = undefined;
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
        _ = im.ImGui_Begin("MakePack###main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoSavedSettings |
            im.ImGuiWindowFlags_NoBringToFrontOnFocus | im.ImGuiWindowFlags_MenuBar | im.ImGuiWindowFlags_NoScrollbar);
        im.ImGui_PopStyleVar();
        mw.main_focused = im.ImGui_IsWindowFocused(im.ImGuiFocusedFlags_RootAndChildWindows);
        mw.trackBounds();
        // The title as an item (automation reads it; ImGui keeps a window's first name for "###" windows).
        const top = im.ImGui_GetCursorPos();
        const tl = std.mem.printSentinel(&nb, "{s}###title", .{mw.title[0..mw.title_len]}, 0) catch "###title";
        im.ImGui_SetCursorPos(.{ .x = top.x + 4, .y = top.y + 1 }); // inside the clip rect, or ImGui drops it
        _ = im.ImGui_InvisibleButton(tl.ptr, .{ .x = 2, .y = 2 }, 0);
        im.ImGui_SetCursorPos(top);
        if (modal) {
            im.ImGui_PushStyleVar(im.ImGuiStyleVar_DisabledAlpha, 1.0);
            im.ImGui_BeginDisabled(true);
        }
        mw.menuBar();
        mw.ctx.updates.banner(mw.ctx);
        im.ImGui_IndentEx(6 * mw.scale());
        mw.toolbar();
        mw.addressBar();
        im.ImGui_UnindentEx(6 * mw.scale());
        mw.body();
        mw.statusBar();
        if (modal) {
            im.ImGui_EndDisabled();
            im.ImGui_PopStyleVar();
        }
        im.ImGui_End();
        if (mw.after) |a| {
            mw.after = null;
            switch (a) {
                .activate => |i| mw.act(mw.m.activate(i, false)),
                .rename => mw.commitRename(),
            }
        } else if (!modal and mw.edit == null and !mw.skip_keys) mw.hotkeys();
        mw.skip_keys = false;
        if (mw.drag_req) {
            mw.drag_req = false;
            if (!modal) mw.dragOut();
        }
        return !mw.closed;
    }

    fn scale(mw: *const MainWindow) f32 {
        return mw.ctx.app.scale();
    }

    fn syncTitle(mw: *MainWindow) void {
        var buf: [1024]u8 = undefined;
        const t = mw.m.titleText(&buf);
        if (std.mem.eql(u8, t, mw.title[0..mw.title_len])) return;
        @memcpy(mw.title[0..t.len], t);
        mw.title_len = t.len;
        mw.ctx.app.setTitle(t);
    }

    /// On disk the list follows the folder (new archives, extracted files) like Explorer's does.
    fn syncWatch(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        const want: ?[]const u8 = if (mw.m.a == null) mw.m.dir else null;
        if (want == null and mw.watched == null) return;
        if (want != null and mw.watched != null and std.mem.eql(u8, want.?, mw.watched.?)) return;
        if (mw.watched) |d| gpa.free(d);
        mw.watched = null;
        mw.watcher.stop(gpa);
        if (want) |d| {
            mw.watched = gpa.dupe(u8, d) catch return;
            mw.watcher.watch(gpa, d);
        }
    }

    // ---- menu (classic archiver main menu) -----------------------------------------------------------------------

    fn menuBar(mw: *MainWindow) void {
        if (!im.ImGui_BeginMenuBar()) return;
        defer im.ImGui_EndMenuBar();
        const arc = mw.m.a != null;
        if (beginMenu(S.tr().mFile, "mfile")) {
            if (item(S.tr().openArchive, "m_open", "Ctrl+O", true)) mw.doOpen();
            if (item(S.tr().newArchive, "m_new", "Ctrl+N", true)) mw.ctx.dialogs.compress(&.{}, true);
            if (item(S.tr().changeDrive, "m_drive", "Ctrl+D", true)) mw.open_drives = true;
            im.ImGui_Separator();
            if (item(S.tr().copyFiles, "m_copy", "Ctrl+C", true)) mw.copyFiles();
            if (item(S.tr().pasteFiles, "m_paste", "Ctrl+V", true)) mw.pasteFiles();
            if (item(S.tr().copyNames, "m_names", null, true)) mw.copyNames();
            im.ImGui_Separator();
            if (item(S.tr().selectAllItems, "m_selall", "Ctrl+A", true)) mw.m.selectAll();
            if (item(S.tr().selectGroup, "m_selgroup", "Num +", true)) mw.selectGroup(true);
            if (item(S.tr().deselectGroup, "m_deselgroup", "Num \u{2212}", true)) mw.selectGroup(false);
            if (item(S.tr().invertSelection, "m_invert", "Num *", true)) mw.m.invert();
            im.ImGui_Separator();
            if (item(S.tr().exit, "m_exit", null, true)) mw.closed = true;
            im.ImGui_EndMenu();
        }
        if (beginMenu(S.tr().mCommands, "mcommands")) {
            if (item(S.tr().addCmd, "m_add", "Alt+A", true)) mw.doAdd();
            if (item(S.tr().extractTo, "m_extract", "Alt+E", true)) mw.doExtract();
            if (item(S.tr().testCmd, "m_test", "Alt+T", true)) mw.doTest();
            im.ImGui_Separator();
            if (item(S.tr().viewCmd, "m_view", "Alt+V", true)) mw.doView();
            if (item(S.tr().deleteCmd, "m_delete", "Del", true)) mw.doDelete(false);
            if (item(S.tr().rename, "m_rename", "F2", true)) mw.beginRename();
            im.ImGui_Separator();
            if (item(S.tr().extractNoAsk, "m_extractnoask", "Alt+W", true)) mw.doExtractNoAsk();
            im.ImGui_EndMenu();
        }
        if (beginMenu(S.tr().mTools, "mtools")) {
            if (item(S.tr().convertMenu, "m_convert", "Alt+Q", true)) mw.doConvert();
            im.ImGui_Separator();
            if (item(S.tr().findCmd, "m_find", "F3", true)) mw.doFind();
            if (item(S.tr().infoCmd, "m_info", "Alt+I", true)) mw.doInfo();
            if (beginMenuEx(S.tr().reportMenu, "m_report", arc)) {
                mw.reportItems(true);
                im.ImGui_EndMenu();
            }
            im.ImGui_EndMenu();
        }
        if (beginMenu(S.tr().mFavorites, "mfavorites")) {
            menu_gutter = true;
            defer menu_gutter = false;
            if (iconItem(.favorite, S.tr().addFavorite, "m_addfav", "Ctrl+F")) mw.beginAddFavorite();
            if (item(S.tr().organizeFavorites, "m_orgfav", null, true)) mw.ctx.dialogs.organizeFavorites();
            const favs = settings.current().Favorites;
            if (favs.len > 0) im.ImGui_Separator();
            for (favs, 0..) |f, i| {
                var lb: [600]u8 = undefined;
                var kb: [16]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}{s}###fav{d}", .{ gutter(), f.Name, i }, 0) catch continue;
                var sc: ?[*:0]const u8 = null;
                if (i < 10) {
                    if (std.mem.printSentinel(&kb, "Ctrl+{d}", .{(i + 1) % 10}, 0)) |z| sc = z.ptr else |_| {}
                }
                if (im.ImGui_MenuItemEx(label.ptr, sc, false, true)) mw.goFavorite(i);
            }
            im.ImGui_EndMenu();
        }
        if (beginMenu(S.tr().mOptions, "moptions")) {
            if (item(S.tr().settingsMenu, "m_settings", "Ctrl+S", true)) mw.ctx.dialogs.settings();
            if (item(S.tr().assoc, "m_assoc", null, true)) mw.ctx.dialogs.assoc();
            im.ImGui_Separator();
            if (beginMenuEx(S.tr().fileListMenu, "m_filelist", true)) {
                if (checkItem(S.tr().flatView, "m_flat", "Ctrl+H", mw.m.flat, arc)) mw.toggleFlat();
                im.ImGui_Separator();
                if (checkItem(S.tr().listMode, "m_list", null, mw.list_mode, true)) mw.setListMode(true);
                if (checkItem(S.tr().detailsMode, "m_details", null, !mw.list_mode, true)) mw.setListMode(false);
                im.ImGui_EndMenu();
            }
            if (checkItem(S.tr().folderTree, "m_tree", "Ctrl+T", mw.show_tree, true)) mw.toggleTree();
            im.ImGui_EndMenu();
        }
        if (beginMenu(S.tr().mHelp, "mhelp")) {
            if (item(S.tr().checkUpdates, "m_updates", null, true)) mw.ctx.updates.checkNow(mw.ctx);
            if (item(S.tr().about, "m_about", null, true)) {
                var b: [512]u8 = undefined;
                const text = std.mem.print(&b, "{s} {s}\n\n{s}", .{ S.app, version, S.tr().aboutText }) catch S.app;
                mw.ctx.dialogs.alert(.info, S.tr().about, text);
            }
            im.ImGui_EndMenu();
        }
    }

    fn reportItems(mw: *MainWindow, keys: bool) void {
        if (item(S.tr().reportHtml, "rep_html", if (keys) "Alt+G" else null, true)) mw.saveReport(true);
        if (item(S.tr().reportTxt, "rep_txt", null, true)) mw.saveReport(false);
        if (item(S.tr().reportCopy, "rep_copy", null, true)) mw.copyReport();
    }

    // ---- toolbar: 32 px pictures with the label under them, a set per mode ---------------------------------

    /// Item id ###tb_<id>. Pictures with distinct silhouettes (the four box icons looked alike at toolbar size).
    const Tool = struct { id: []const u8, icon: kit.icons.Name, text: S.Key, tip: S.Key, key: []const u8, archive_only: bool = false };
    const tools = [_]Tool{
        .{ .id = "add", .icon = .pack, .text = .tbAdd, .tip = .addCmd, .key = "Alt+A" },
        .{ .id = "extract", .icon = .extract, .text = .tbExtract, .tip = .extractTo, .key = "Alt+E" },
        .{ .id = "test", .icon = .ok, .text = .tbTest, .tip = .testCmd, .key = "Alt+T" },
        .{ .id = "view", .icon = .view, .text = .tbView, .tip = .viewCmd, .key = "Alt+V" },
        .{ .id = "delete", .icon = .delete, .text = .tbDelete, .tip = .deleteCmd, .key = "Del" },
        .{ .id = "find", .icon = .find, .text = .tbFind, .tip = .findCmd, .key = "F3" },
        .{ .id = "info", .icon = .info, .text = .tbInfo, .tip = .infoCmd, .key = "Alt+I" },
        .{ .id = "convert", .icon = .refresh, .text = .tbConvert, .tip = .convertMenu, .key = "Alt+Q" },
        .{ .id = "report", .icon = .report, .text = .tbReport, .tip = .reportMenu, .key = "", .archive_only = true },
    };

    fn toolbar(mw: *MainWindow) void {
        const s = mw.scale();
        const icon = kit.icons.pixels(32);
        const text_h = im.ImGui_GetTextLineHeight();
        const h = icon + text_h + 8 * s;
        im.ImGui_Dummy(.{ .x = 0, .y = 2 * s });
        for (tools, 0..) |t, i| {
            if (t.archive_only and mw.m.a == null) continue;
            if (i > 0) im.ImGui_SameLineEx(0, 2 * s);
            if (i == 5) { // the separator between the groups
                const p = im.ImGui_GetCursorScreenPos();
                im.ImDrawList_AddLineEx(im.ImGui_GetWindowDrawList(), .{ .x = p.x + 3 * s, .y = p.y + 4 * s }, .{ .x = p.x + 3 * s, .y = p.y + h - 4 * s }, im.ImGui_GetColorU32(im.ImGuiCol_Separator), 1, 0);
                im.ImGui_Dummy(.{ .x = 6 * s, .y = h });
                im.ImGui_SameLineEx(0, 2 * s);
            }
            var lb: [128]u8 = undefined;
            const text = S.get(t.text);
            const label = std.mem.printSentinel(&lb, "{s}###tb_{s}", .{ text, t.id }, 0) catch continue;
            const tw = im.ImGui_CalcTextSize(text.ptr).x;
            const bw = @max(tw, icon) + 16 * s; // 8 px of highlight either side of a long label ("Hinzufügen")
            const p = im.ImGui_GetCursorScreenPos();
            const clicked = im.ImGui_InvisibleButton(label.ptr, .{ .x = bw, .y = h }, 0);
            const dl = im.ImGui_GetWindowDrawList();
            if (im.ImGui_IsItemHovered(0) or im.ImGui_IsItemActive()) {
                const col = im.ImGui_GetColorU32(if (im.ImGui_IsItemActive()) im.ImGuiCol_HeaderActive else im.ImGuiCol_HeaderHovered);
                im.ImDrawList_AddRectFilledEx(dl, p, .{ .x = p.x + bw, .y = p.y + h }, col, 4 * s, 0);
            }
            const ix = @round(p.x + (bw - icon) / 2); // whole pixels: the texture maps 1:1
            const iy = @round(p.y + 3 * s);
            if (kit.icons.get(t.icon, 32)) |tex| im.ImDrawList_AddImage(dl, tex, .{ .x = ix, .y = iy }, .{ .x = ix + icon, .y = iy + icon });
            im.ImDrawList_AddText(dl, .{ .x = p.x + (bw - tw) / 2, .y = p.y + 4 * s + icon }, im.ImGui_GetColorU32(im.ImGuiCol_Text), text.ptr);
            var pb: [96]u8 = undefined;
            if (t.key.len > 0) tooltip("{s} ({s})", .{ S.plain(&pb, S.get(t.tip)), t.key }) else tooltip("{s}", .{S.get(t.tip)});
            if (clicked) mw.toolClicked(i);
        }
        if (im.ImGui_BeginPopup("##report_menu", 0)) {
            mw.reportItems(false);
            im.ImGui_EndPopup();
        }
    }

    fn toolClicked(mw: *MainWindow, i: usize) void {
        switch (i) {
            0 => mw.doAdd(),
            1 => mw.doExtract(),
            2 => mw.doTest(),
            3 => mw.doView(),
            4 => mw.doDelete(false),
            5 => mw.doFind(),
            6 => mw.doInfo(),
            7 => mw.doConvert(),
            else => _ = im.ImGui_OpenPopup("##report_menu", 0),
        }
    }

    // ---- Up + address bar ----------------------------------------------------------------------------------

    fn addressBar(mw: *MainWindow) void {
        const s = mw.scale();
        const up_clicked = kit.ui.iconButton("up", .up, 16, null);
        tooltip("{s} (Backspace)", .{S.tr().up});
        if (up_clicked) mw.nav(mw.m.up());
        im.ImGui_SameLineEx(0, 4 * s);
        if (!mw.address_active) {
            var ab: [2048]u8 = undefined;
            const t = mw.m.addressText(&ab);
            const n = @min(t.len, mw.address.len - 1);
            @memcpy(mw.address[0..n], t[0..n]);
            mw.address[n] = 0;
        }
        im.ImGui_SetNextItemWidth(im.ImGui_GetContentRegionAvail().x - kit.ui.dropArrowWidth());
        const enter = im.ImGui_InputText("##address", &mw.address, mw.address.len, im.ImGuiInputTextFlags_EnterReturnsTrue);
        mw.address_active = im.ImGui_IsItemActive();
        if (enter) {
            mw.address_active = false;
            const text = std.mem.sliceTo(&mw.address, 0);
            const copy = mw.ctx.gpa.dupe(u8, text) catch return;
            defer mw.ctx.gpa.free(copy);
            mw.nav(mw.m.goTyped(copy));
            mw.focus_list = true;
            mw.skip_keys = true;
        }
        im.ImGui_SameLineEx(0, 0); // the arrow joins the box
        if (kit.ui.dropArrow("##address_drop", im.ImGui_IsPopupOpen("##drives", 0))) mw.open_drives = true;
        if (mw.open_drives) {
            mw.open_drives = false;
            _ = im.ImGui_OpenPopup("##drives", 0);
        }
        im.ImGui_SetNextWindowSizeConstraints(.{ .x = 300 * s, .y = 0 }, .{ .x = 2000 * s, .y = 500 * s }, null, null);
        if (im.ImGui_BeginPopup("##drives", 0)) {
            defer im.ImGui_EndPopup();
            mw.addressList();
        }
    }

    /// The drop-down: drives, then the places visited (most recent first).
    fn addressList(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        const ds = shell.drives(gpa) catch return;
        defer {
            for (ds) |d| gpa.free(d);
            gpa.free(ds);
        }
        for (ds, 0..) |d, i| {
            var lb: [300]u8 = undefined;
            const label = std.mem.printSentinel(&lb, "{s}###drv{d}", .{ shell.driveName(d), i }, 0) catch continue;
            kit.ui.icon(.drive, 16);
            im.ImGui_SameLine();
            if (im.ImGui_Selectable(label.ptr)) {
                mw.nav(mw.m.go(.{ .path = d }, null, true));
                return;
            }
        }
        var shown: usize = 0;
        var i = mw.m.back.items.len;
        outer: while (i > 0 and shown < 15) {
            i -= 1;
            const l = mw.m.back.items[i].loc;
            for (mw.m.back.items[i + 1 ..]) |later| if (sameLoc(later.loc, l)) continue :outer;
            shown += 1;
            if (shown == 1) im.ImGui_Separator();
            var tb: [2048]u8 = undefined;
            var o: std.Io.Writer = .fixed(&tb);
            o.writeAll(l.path) catch {};
            if (l.inner) |inner| if (inner.len > 0) {
                o.writeAll("\\") catch {};
                for (std.mem.trimEnd(u8, inner, "/")) |c| o.writeByte(if (c == '/') '\\' else c) catch {};
            };
            o.print("###hist{d}", .{i}) catch {};
            o.writeByte(0) catch continue;
            const label: [*:0]const u8 = @ptrCast(o.buffered().ptr);
            if (im.ImGui_Selectable(label)) {
                var saved = model.Saved.init(gpa, l) catch return;
                defer saved.deinit();
                mw.nav(mw.m.go(saved.loc, null, true));
                return;
            }
        }
    }

    fn sameLoc(x: model.Loc, y: model.Loc) bool {
        if (!C.engine.samePath(x.path, y.path)) return false;
        if (x.inner == null or y.inner == null) return x.inner == null and y.inner == null;
        return std.mem.eql(u8, x.inner.?, y.inner.?);
    }

    // ---- tree | list ----------------------------------------------------------------------------------------

    fn body(mw: *MainWindow) void {
        const s = mw.scale();
        im.ImGui_Dummy(.{ .x = 0, .y = 1 * s });
        // The status bar below: a spacer, one framed line, a margin.
        const status_h = 1 * s + im.ImGui_GetFrameHeight() + im.ImGui_GetStyle().*.ItemSpacing.y * 2 + 4 * s;
        const h = @max(50 * s, im.ImGui_GetContentRegionAvail().y - status_h);
        if (mw.show_tree) {
            const tw = std.math.clamp(mw.tree_w * s, 80 * s, im.ImGui_GetContentRegionAvail().x - 120 * s);
            if (im.ImGui_BeginChild("##tree", .{ .x = tw, .y = h }, im.ImGuiChildFlags_Borders, im.ImGuiWindowFlags_HorizontalScrollbar)) mw.drawTree();
            im.ImGui_EndChild();
            im.ImGui_SameLineEx(0, 0);
            _ = im.ImGui_InvisibleButton("##split", .{ .x = 5 * s, .y = h }, 0);
            if (im.ImGui_IsItemHovered(0) or im.ImGui_IsItemActive()) im.ImGui_SetMouseCursor(im.ImGuiMouseCursor_ResizeEW);
            if (im.ImGui_IsItemActive()) mw.tree_w = std.math.clamp(mw.tree_w + im.ImGui_GetIO().*.MouseDelta.x / s, 80, 2000);
            im.ImGui_SameLineEx(0, 0);
        }
        if (mw.focus_list) {
            mw.focus_list = false;
            im.ImGui_SetNextWindowFocus();
        }
        if (im.ImGui_BeginChild("##list", .{ .x = 0, .y = h }, im.ImGuiChildFlags_Borders, if (mw.list_mode) im.ImGuiWindowFlags_HorizontalScrollbar else 0)) {
            if (mw.list_mode) mw.drawListMode() else mw.drawDetails();
            mw.contextMenu();
        }
        im.ImGui_EndChild();
    }

    /// Palette pictures instead of Explorer's (colourful, off-theme): folder, archive, any other file.
    fn rowIcon(r: Row) kit.icons.Name {
        if (r.up or r.folder) return .folder;
        return if (isArchiveName(r.name)) .pack else .document;
    }

    fn isArchiveName(name: []const u8) bool {
        return types.isArchiveExt(std.mem.trimStart(u8, pw.extension(name), "."));
    }

    fn rowLabel(buf: []u8, r: Row) [:0]const u8 {
        return std.mem.printSentinel(buf, "{s}###r", .{r.name}, 0) catch "?###r";
    }

    fn drawDetails(mw: *MainWindow) void {
        const m = &mw.m;
        const s = mw.scale();
        const cols = m.cols;
        const id: [*:0]const u8 = if (m.a == null) "##files_disk" else if (m.flat) "##files_flat" else "##files_arc";
        const flags = im.ImGuiTableFlags_Resizable | im.ImGuiTableFlags_Reorderable | im.ImGuiTableFlags_Sortable | im.ImGuiTableFlags_RowBg |
            im.ImGuiTableFlags_BordersInnerV | im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_SizingFixedFit;
        if (!im.ImGui_BeginTable(id, @intCast(cols.len), flags)) return;
        defer im.ImGui_EndTable();
        // The text columns (Name, Type, flat view's Path) share what the fixed number columns leave, in C#'s
        // proportions (300/150/220); no horizontal scrolling, so every column stays on screen.
        for (cols) |c| {
            var lb: [64]u8 = undefined;
            const label = std.mem.printSentinel(&lb, "{s}###c_{t}", .{ colTitle(c), c }, 0) catch continue;
            const stretch = c == .name or c == .type or c == .path;
            var cf: im.ImGuiTableColumnFlags = if (stretch) im.ImGuiTableColumnFlags_WidthStretch else im.ImGuiTableColumnFlags_WidthFixed;
            if (c == .name) cf |= im.ImGuiTableColumnFlags_DefaultSort | im.ImGuiTableColumnFlags_NoHide;
            const wd: f32 = switch (c) {
                .name => 3, // weights
                .type => 1.5,
                .path => 2.2,
                .modified => 112 * s,
                .crc => 66 * s,
                else => 78 * s,
            };
            im.ImGui_TableSetupColumnEx(label.ptr, cf, wd, @backingInt(c));
        }
        im.ImGui_TableSetupScrollFreeze(0, 1);
        headersRow(cols);
        if (im.ImGui_TableGetSortSpecs()) |specs| {
            if ((specs.*.SpecsDirty or mw.sorted_ver != m.version) and specs.*.SpecsCount > 0) {
                const spec = specs.*.Specs[0];
                const c: Col = @fromBackingInt(@intCast(spec.ColumnUserID));
                m.sortBy(c, spec.SortDirection != im.ImGuiSortDirection_Descending);
                specs.*.SpecsDirty = false;
            }
            mw.sorted_ver = m.version;
        }
        const rows = m.rows.items;
        const ms = im.ImGui_BeginMultiSelectEx(im.ImGuiMultiSelectFlags_ClearOnEscape | im.ImGuiMultiSelectFlags_BoxSelect1d |
            im.ImGuiMultiSelectFlags_NoSelectAll | im.ImGuiMultiSelectFlags_ClearOnClickVoid, @intCast(m.selectedCount()), @intCast(rows.len));
        mw.applySelection(ms);
        var clipper = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clipper, @intCast(rows.len), -1);
        if (ms.*.RangeSrcItem >= 0 and ms.*.RangeSrcItem < rows.len) im.ImGuiListClipper_IncludeItemByIndex(&clipper, @intCast(ms.*.RangeSrcItem));
        if (m.scroll) if (m.focus) |f| im.ImGuiListClipper_IncludeItemByIndex(&clipper, @intCast(f));
        if (mw.edit) |e| if (e < rows.len) im.ImGuiListClipper_IncludeItemByIndex(&clipper, @intCast(e));
        var cb: [96]u8 = undefined;
        var lb: [1100]u8 = undefined;
        while (im.ImGuiListClipper_Step(&clipper)) {
            var i: usize = @intCast(clipper.DisplayStart);
            while (i < @as(usize, @intCast(clipper.DisplayEnd))) : (i += 1) {
                const r = m.rows.items[i];
                im.ImGui_TableNextRow();
                im.ImGui_PushIDInt(@intCast(i));
                defer im.ImGui_PopID();
                for (cols, 0..) |c, ci| {
                    _ = im.ImGui_TableSetColumnIndex(@intCast(ci));
                    if (c == .name) {
                        lineIcon(rowIcon(r), im.ImGui_GetTextLineHeight()); // 22 px rows (kit table pitch)
                        im.ImGui_SameLine();
                        if (mw.edit == i) {
                            mw.renameBox();
                        } else {
                            mw.rowItem(i, rowLabel(&lb, r), .{ .x = 0, .y = 0 }, im.ImGuiSelectableFlags_SpanAllColumns | im.ImGuiSelectableFlags_AllowOverlap);
                        }
                        continue;
                    }
                    const t = m.cell(&cb, r, c);
                    if (c == .size or c == .@"packed") {
                        const tw = im.ImGui_CalcTextSizeEx(t.ptr, t.ptr + t.len, false, -1).x;
                        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, im.ImGui_GetContentRegionAvail().x - tw));
                    }
                    im.ImGui_TextUnformattedEx(t.ptr, t.ptr + t.len);
                }
            }
        }
        mw.applySelection(im.ImGui_EndMultiSelect());
    }

    /// TableHeadersRow with the number columns' titles right-aligned over their right-aligned numbers.
    fn headersRow(cols: []const Col) void {
        im.ImGui_TableNextRowEx(im.ImGuiTableRowFlags_Headers, im.ImGui_GetTextLineHeight() + im.ImGui_GetStyle().*.CellPadding.y * 2);
        for (cols, 0..) |c, ci| {
            const n: c_int = @intCast(ci);
            if (!im.ImGui_TableSetColumnIndex(n)) continue;
            const name = im.ImGui_TableGetColumnName(n);
            if (c == .size or c == .@"packed") {
                const st = im.ImGui_GetStyle();
                // the sort arrow (ImGui: FontSize * 0.65 + FramePadding.x) sits right of a sorted title
                const arrow = if (im.ImGui_TableGetColumnFlags(n) & im.ImGuiTableColumnFlags_IsSorted != 0) @trunc(im.ImGui_GetFontSize() * 0.65 + st.*.FramePadding.x) - st.*.CellPadding.x else 0;
                const tw = im.ImGui_CalcTextSizeEx(name, null, true, -1).x;
                im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, im.ImGui_GetContentRegionAvail().x - tw - arrow));
            }
            im.ImGui_PushIDInt(n); // the ids TableHeadersRow gives
            im.ImGui_TableHeader(name);
            im.ImGui_PopID();
        }
    }

    /// One row's selectable: selection (multi-select), focus, double click, the start of a drag-out.
    fn rowItem(mw: *MainWindow, i: usize, label: [:0]const u8, size: im.ImVec2, flags: im.ImGuiSelectableFlags) void {
        const m = &mw.m;
        const r = m.rows.items[i];
        im.ImGui_SetNextItemSelectionUserData(@intCast(i));
        // The palette's hover tint is weaker than the selection: a hovered selected row looked unselected. Stronger.
        if (r.selected) im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderHovered, im.ImGui_GetStyleColorVec4(im.ImGuiCol_HeaderActive).*);
        _ = im.ImGui_SelectableEx(label.ptr, r.selected, flags | im.ImGuiSelectableFlags_AllowDoubleClick, size);
        if (r.selected) im.ImGui_PopStyleColor();
        if (im.ImGui_IsItemFocused()) m.focus = i;
        if (m.scroll and m.focus == i) {
            im.ImGui_SetScrollHereY(0.5);
            m.scroll = false;
        }
        if (im.ImGui_IsItemHovered(0) and im.ImGui_IsMouseDoubleClicked(0)) {
            m.focus = i;
            mw.after = .{ .activate = i };
        }
        if (im.ImGui_IsItemActive() and im.ImGui_IsMouseDragging(0, -1) and r.selected and !r.up and !mw.dragging) mw.drag_req = true;
    }

    fn applySelection(mw: *MainWindow, ms: [*c]im.ImGuiMultiSelectIO) void {
        if (ms == null) return;
        const rows = mw.m.rows.items;
        const reqs = ms.*.Requests;
        if (reqs.Size == 0) return;
        for (reqs.Data[0..@intCast(reqs.Size)]) |req| {
            if (req.Type == im.ImGuiSelectionRequestType_SetAll) {
                for (rows) |*r| r.selected = req.Selected and !r.up;
            } else if (req.Type == im.ImGuiSelectionRequestType_SetRange) {
                const a: usize = @intCast(@max(0, req.RangeFirstItem));
                const b: usize = @intCast(@max(0, req.RangeLastItem));
                var k = a;
                while (k <= b and k < rows.len) : (k += 1) rows[k].selected = req.Selected;
            }
        }
        mw.m.setMessage(null);
    }

    /// View.List: names flowing top to bottom, then left to right.
    // ponytail: no clipping in List mode (every name is submitted); Details is the mode for huge folders.
    fn drawListMode(mw: *MainWindow) void {
        const m = &mw.m;
        const s = mw.scale();
        const rows = m.rows.items;
        const line = im.ImGui_GetTextLineHeightWithSpacing() + 2 * s;
        const avail = im.ImGui_GetContentRegionAvail();
        const per_col: usize = @max(1, @as(usize, @intFromFloat(@max(1, (avail.y - im.ImGui_GetStyle().*.ScrollbarSize) / line))));
        var col_w: f32 = 80 * s;
        for (rows) |r| col_w = @max(col_w, im.ImGui_CalcTextSizeEx(r.name.ptr, r.name.ptr + r.name.len, false, -1).x + 40 * s);
        col_w = @min(col_w, 400 * s);
        // ponytail: no BoxSelect2d here - with it a click in the context menu reached the list underneath (cleared
        // the selection, the item never fired). Rubber-band selection is a Details-mode feature.
        const ms = im.ImGui_BeginMultiSelectEx(im.ImGuiMultiSelectFlags_ClearOnEscape |
            im.ImGuiMultiSelectFlags_NoSelectAll | im.ImGuiMultiSelectFlags_ClearOnClickVoid, @intCast(m.selectedCount()), @intCast(rows.len));
        mw.applySelection(ms);
        const origin = im.ImGui_GetCursorPos();
        var lb: [1100]u8 = undefined;
        for (rows, 0..) |r, i| {
            im.ImGui_SetCursorPos(.{ .x = origin.x + @as(f32, @floatFromInt(i / per_col)) * col_w, .y = origin.y + @as(f32, @floatFromInt(i % per_col)) * line });
            im.ImGui_PushIDInt(@intCast(i));
            defer im.ImGui_PopID();
            lineIcon(rowIcon(r), im.ImGui_GetTextLineHeight());
            im.ImGui_SameLine();
            if (mw.edit == i) {
                im.ImGui_SetNextItemWidth(col_w - 24 * s);
                mw.renameBox();
            } else mw.rowItem(i, rowLabel(&lb, r), .{ .x = col_w - 24 * s, .y = 0 }, 0);
        }
        mw.applySelection(im.ImGui_EndMultiSelect());
    }

    // ---- folder tree -------------------------------------------------------------------------------------

    fn drawTree(mw: *MainWindow) void {
        const m = &mw.m;
        if (!mw.tree.built or mw.tree.arc != m.a) mw.buildTree();
        if (mw.tree.ver != m.version) {
            mw.tree.ver = m.version;
            mw.tree.sync = true;
        }
        for (mw.tree.roots.items) |*n| mw.drawNode(n);
        mw.tree.sync = false;
    }

    fn buildTree(mw: *MainWindow) void {
        const t = &mw.tree;
        _ = t.arena.reset(.retain_capacity);
        t.roots = .empty;
        t.arc = mw.m.a;
        t.built = true;
        t.sync = true;
        const ar = t.arena.allocator();
        if (mw.m.a) |a| {
            var root: Node = .{ .label = ar.dupe(u8, a.display()) catch return, .key = "", .loaded = true };
            // Every folder of the archive as "a/", "a/b/" - also the ones only implied by file paths.
            for (a.items(), mw.m.names) |it, n| {
                const end = if (it.is_dir) n.len else std.mem.findScalarLast(u8, n, '/') orelse 0;
                if (end == 0) continue;
                var node = &root;
                var start: usize = 0;
                while (start < end) {
                    const slash = std.mem.findScalarPos(u8, n, start, '/') orelse n.len;
                    const seg = n[start..@min(slash, end)];
                    const path = n[0..@min(slash, end)];
                    var found: ?*Node = null;
                    for (node.children.items) |*c| if (eqlI(c.label, seg)) {
                        found = c;
                        break;
                    };
                    if (found == null) {
                        const k = std.mem.concat(ar, u8, &.{ path, "/" }) catch return;
                        node.children.append(ar, .{ .label = seg, .key = k, .loaded = true }) catch return;
                        found = &node.children.items[node.children.items.len - 1];
                    }
                    node = found.?;
                    start = slash + 1;
                }
            }
            sortNodes(&root);
            t.roots.append(ar, root) catch {};
            return;
        }
        const ds = shell.drives(ar) catch return;
        for (ds) |d| t.roots.append(ar, .{ .label = shell.driveName(d), .key = d, .loaded = false, .drive = true }) catch {};
    }

    fn sortNodes(n: *Node) void {
        std.mem.sort(Node, n.children.items, {}, struct {
            fn f(_: void, a: Node, b: Node) bool {
                return shell.compareText(a.label, b.label) == .lt;
            }
        }.f);
        for (n.children.items) |*c| sortNodes(c);
    }

    fn loadChildren(mw: *MainWindow, n: *Node) void {
        if (n.loaded) return;
        n.loaded = true;
        const ar = mw.tree.arena.allocator();
        const pattern = kit.win.toW(ar, std.mem.concat(ar, u8, &.{ std.mem.trimEnd(u8, n.key, "\\"), "\\*" }) catch return) catch return;
        var fd: w.WIN32_FIND_DATAW = undefined;
        const h = w.FindFirstFileExW(pattern.ptr, w.FindExInfoBasic, &fd, w.FindExSearchLimitToDirectories, null, w.FIND_FIRST_EX_LARGE_FETCH);
        if (h == w.INVALID_HANDLE_VALUE) return; // no access: a leaf
        defer _ = w.FindClose(h);
        while (true) {
            if (fd.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY != 0) {
                const name = kit.win.fromWZ(ar, @ptrCast(&fd.cFileName)) catch break;
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
                    n.children.append(ar, .{ .label = name, .key = model.join(ar, n.key, name) catch break, .loaded = false }) catch break;
            }
            if (w.FindNextFileW(h, &fd) == 0) break;
        }
        std.mem.sort(Node, n.children.items, {}, struct {
            fn f(_: void, a: Node, b: Node) bool {
                return shell.compareText(a.label, b.label) == .lt;
            }
        }.f);
    }

    /// Where the tree's selection belongs: the folder on disk, or "cur" in the archive.
    fn treeTarget(mw: *const MainWindow) []const u8 {
        return if (mw.m.a != null) mw.m.cur else mw.m.dir;
    }

    fn isAncestor(mw: *const MainWindow, key: []const u8) bool {
        const target = mw.treeTarget();
        if (mw.m.a != null) return key.len == 0 or (target.len >= key.len and std.ascii.eqlIgnoreCase(target[0..key.len], key));
        const k = std.mem.trimEnd(u8, key, "\\");
        return target.len >= k.len and std.ascii.eqlIgnoreCase(target[0..k.len], k) and (target.len == k.len or target[k.len] == '\\');
    }

    fn isCurrent(mw: *const MainWindow, key: []const u8) bool {
        const target = mw.treeTarget();
        if (mw.m.a != null) return std.ascii.eqlIgnoreCase(key, target);
        return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, key, "\\"), std.mem.trimEnd(u8, target, "\\"));
    }

    fn drawNode(mw: *MainWindow, n: *Node) void {
        const s = mw.scale();
        const current = mw.isCurrent(n.key);
        if (mw.tree.sync and mw.isAncestor(n.key) and !current) {
            mw.loadChildren(n);
            im.ImGui_SetNextItemOpen(true, im.ImGuiCond_Always);
        }
        const gap = kit.icons.pixels(16) + im.ImGui_GetStyle().*.ItemSpacing.x / 2; // the icon + air before the name
        const pad: usize = @intFromFloat(@ceil(gap / spaceWidth()));
        var lb: [1400]u8 = undefined;
        var o: std.Io.Writer = .fixed(lb[0 .. lb.len - 1]);
        o.splatByteAll(' ', @min(pad, 40)) catch {};
        o.print("{s}###t{s}", .{ n.label, n.key }) catch {};
        const len = o.buffered().len;
        lb[len] = 0;
        var flags: im.ImGuiTreeNodeFlags = im.ImGuiTreeNodeFlags_OpenOnArrow | im.ImGuiTreeNodeFlags_OpenOnDoubleClick | im.ImGuiTreeNodeFlags_SpanAvailWidth;
        if (current) flags |= im.ImGuiTreeNodeFlags_Selected;
        if (n.loaded and n.children.items.len == 0) flags |= im.ImGuiTreeNodeFlags_Leaf;
        if (mw.m.a != null and n.key.len == 0) flags |= im.ImGuiTreeNodeFlags_DefaultOpen;
        const opened = im.ImGui_TreeNodeEx(@ptrCast(&lb), flags);
        const min = im.ImGui_GetItemRectMin();
        const ix = min.x + im.ImGui_GetFontSize() + im.ImGui_GetStyle().*.FramePadding.x * 2;
        const pic: kit.icons.Name = if (n.drive) .drive else if (mw.m.a != null and n.key.len == 0) (if (mw.m.encrypted) .archive_locked else .pack) else .folder;
        drawIcon16(pic, .{ .x = ix, .y = min.y }, im.ImGui_GetItemRectMax().y - min.y);
        if (current and mw.tree.sync) {
            im.ImGui_SetScrollHereY(0.5);
            // A deep folder in a narrow tree: scroll right until its name shows.
            const wx = im.ImGui_GetWindowPos().x;
            const label_end = ix + gap + im.ImGui_CalcTextSize(lb[0..len :0].ptr + @min(pad, 40)).x;
            if (label_end > wx + im.ImGui_GetWindowWidth() - im.ImGui_GetStyle().*.ScrollbarSize)
                im.ImGui_SetScrollX(@max(0, ix - wx + im.ImGui_GetScrollX() - 24 * s));
        }
        if (im.ImGui_IsItemClicked() and !im.ImGui_IsItemToggledOpen()) mw.treeClicked(n.key);
        if (!opened) return;
        mw.loadChildren(n);
        for (n.children.items) |*c| mw.drawNode(c);
        im.ImGui_TreePop();
    }

    fn treeClicked(mw: *MainWindow, key: []const u8) void {
        const k = mw.ctx.gpa.dupe(u8, key) catch return;
        defer mw.ctx.gpa.free(k);
        if (mw.m.a) |a| {
            mw.nav(mw.m.go(.{ .path = a.source, .inner = k, .password = a.password, .parents = mw.m.parents }, null, true));
        } else mw.nav(mw.m.go(.{ .path = k }, null, true));
    }

    // ---- status bar: drive and lock pictures on the left, the totals on the right -------------------------

    fn statusBar(mw: *MainWindow) void {
        const s = mw.scale();
        im.ImGui_Dummy(.{ .x = 0, .y = 1 * s });
        im.ImGui_IndentEx(6 * s);
        defer im.ImGui_UnindentEx(6 * s);
        im.ImGui_AlignTextToFramePadding();
        lineIcon(.drive, im.ImGui_GetFrameHeight());
        const root = if (mw.m.dir.len >= 3 and mw.m.dir[1] == ':') mw.m.dir[0..3] else mw.m.dir;
        tooltip("{s}", .{root});
        if (mw.m.a != null and mw.m.encrypted) {
            im.ImGui_SameLine();
            lineIcon(.lock, im.ImGui_GetFrameHeight());
            im.ImGui_SetItemTooltipUnformatted(S.tr().encrypted.ptr);
        }
        var sb: [512]u8 = undefined;
        const text = mw.m.statusText(&sb);
        var lb: [600]u8 = undefined;
        const label = std.mem.printSentinel(&lb, "{s}###status", .{text}, 0) catch "###status";
        const tw = im.ImGui_CalcTextSizeEx(text.ptr, text.ptr + text.len, false, -1).x;
        im.ImGui_SameLine();
        im.ImGui_SetCursorPosX(@max(im.ImGui_GetCursorPosX(), im.ImGui_GetWindowWidth() - tw - 16 * s));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderHovered, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderActive, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
        _ = im.ImGui_SelectableEx(label.ptr, false, im.ImGuiSelectableFlags_NoAutoClosePopups, .{ .x = tw, .y = 0 });
        im.ImGui_PopStyleColorEx(2);
    }

    // ---- context menu ---------------------------------------------------------------------------------------

    fn contextMenu(mw: *MainWindow) void {
        if (im.ImGui_IsWindowHovered(im.ImGuiHoveredFlags_ChildWindows) and im.ImGui_IsMouseReleased(1)) _ = im.ImGui_OpenPopup("##ctx", 0);
        if (!im.ImGui_BeginPopup("##ctx", 0)) return;
        defer im.ImGui_EndPopup();
        const m = &mw.m;
        const arc = m.a != null;
        const n = m.selectedCount();
        const one: ?Row = if (n == 1) (if (m.oneSelected()) |i| m.rows.items[i] else null) else null;
        var any_file = false;
        for (m.rows.items) |r| if (r.selected and !r.up and !r.folder) {
            any_file = true;
        };
        im.ImGui_PushFontFloat(mw.ctx.app.fonts.bold, 0);
        const open_it = item(S.tr().openCmd, "c_open", "Enter", one != null);
        im.ImGui_PopFont();
        if (open_it) if (m.oneSelected()) |i| mw.act(m.activate(i, false));
        if (item(S.tr().showContents, "c_contents", "Ctrl+PgDn", one != null and !one.?.folder)) if (m.oneSelected()) |i| mw.act(m.activate(i, true));
        if (item(S.tr().viewCmd, "c_view", "Alt+V", one != null and !one.?.folder)) mw.doView();
        im.ImGui_Separator();
        if (item(S.tr().addCmd, "c_add", "Alt+A", arc or n > 0)) mw.doAdd();
        if (item(S.tr().extractTo, "c_extract", "Alt+E", arc or any_file)) mw.doExtract();
        if (item(S.tr().testCmd, "c_test", "Alt+T", arc or any_file)) mw.doTest();
        im.ImGui_Separator();
        if (item(S.tr().copyFiles, "c_copy", "Ctrl+C", n > 0)) mw.copyFiles();
        if (item(S.tr().pasteFiles, "c_paste", "Ctrl+V", shell.hasFiles() and (!arc or m.editable))) mw.pasteFiles();
        im.ImGui_Separator();
        if (!arc and item(S.tr().newFolder, "c_newfolder", null, true)) mw.newFolder();
        if (item(S.tr().rename, "c_rename", "F2", one != null and (!arc or m.editable))) mw.beginRename();
        if (item(S.tr().delete, "c_delete", "Del", n > 0 and (!arc or m.editable))) mw.doDelete(false);
        im.ImGui_Separator();
        if (beginMenuEx(S.tr().viewAs, "c_viewas", true)) {
            if (checkItem(S.tr().listMode, "c_list", null, mw.list_mode, true)) mw.setListMode(true);
            if (checkItem(S.tr().detailsMode, "c_details", null, !mw.list_mode, true)) mw.setListMode(false);
            im.ImGui_EndMenu();
        }
        if (beginMenuEx(S.tr().sortBy, "c_sortby", true)) {
            for (m.cols) |c| {
                var lb: [64]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}###c_sort_{t}", .{ colTitle(c), c }, 0) catch continue;
                if (im.ImGui_MenuItemEx(label.ptr, null, m.sort == c, true)) {
                    m.sortBy(c, m.sort != c or !m.ascending);
                    mw.sorted_ver = m.version; // the header's arrow is ImGui's own: it stays where it was
                }
            }
            im.ImGui_EndMenu();
        }
        if (item(if (arc) S.tr().infoCmd else S.tr().propertiesCmd, "c_info", "Alt+I", true)) mw.doInfo();
    }

    // ---- keys -------------------------------------------------------------------------------------------------

    fn hotkeys(mw: *MainWindow) void {
        if (!mw.main_focused) return;
        const ctrl = im.ImGuiMod_Ctrl;
        const alt = im.ImGuiMod_Alt;
        const shift = im.ImGuiMod_Shift;
        // anywhere in the window
        if (pressed(alt | im.ImGuiKey_LeftArrow)) return mw.nav(mw.m.goBack());
        if (pressed(alt | im.ImGuiKey_RightArrow)) return mw.nav(mw.m.goForward());
        if (pressed(alt | im.ImGuiKey_UpArrow)) return mw.nav(mw.m.up());
        if (pressed(ctrl | im.ImGuiKey_Backslash)) return mw.nav(mw.m.root());
        if (pressed(ctrl | im.ImGuiKey_E) or pressed(alt | im.ImGuiKey_E)) return mw.doExtract(); // Ctrl+E: MakePack's old key
        if (pressed(ctrl | im.ImGuiKey_O)) return mw.doOpen();
        if (pressed(ctrl | im.ImGuiKey_N)) return mw.ctx.dialogs.compress(&.{}, true);
        if (pressed(ctrl | im.ImGuiKey_D)) {
            mw.open_drives = true;
            return;
        }
        if (pressed(alt | im.ImGuiKey_A)) return mw.doAdd();
        if (pressed(alt | im.ImGuiKey_T)) return mw.doTest();
        if (pressed(alt | im.ImGuiKey_V)) return mw.doView();
        if (pressed(alt | im.ImGuiKey_W)) return mw.doExtractNoAsk();
        if (pressed(alt | im.ImGuiKey_Q)) return mw.doConvert();
        if (pressed(alt | im.ImGuiKey_I)) return mw.doInfo();
        if (pressed(alt | im.ImGuiKey_G)) return mw.saveReport(true);
        if (pressed(im.ImGuiKey_F3)) return mw.doFind();
        if (pressed(ctrl | im.ImGuiKey_S)) return mw.ctx.dialogs.settings();
        if (pressed(ctrl | im.ImGuiKey_F)) return mw.beginAddFavorite();
        if (pressed(ctrl | im.ImGuiKey_H)) return mw.toggleFlat();
        if (pressed(ctrl | im.ImGuiKey_T)) return mw.toggleTree();
        for (0..10) |i| if (pressed(ctrl | (im.ImGuiKey_0 + @as(c_int, @intCast((i + 1) % 10))))) return mw.goFavorite(i);
        // the list's keys; in the address bar they edit text
        if (im.ImGui_GetIO().*.WantTextInput) return;
        const m = &mw.m;
        if (pressed(im.ImGuiKey_Backspace) or pressed(ctrl | im.ImGuiKey_PageUp)) return mw.nav(m.up());
        if (pressed(ctrl | im.ImGuiKey_PageDown)) if (m.focus) |f| return mw.act(m.activate(f, true));
        if (pressed(im.ImGuiKey_Enter) or pressed(im.ImGuiKey_KeypadEnter)) if (m.focus) |f| return mw.act(m.activate(f, false));
        if (pressed(im.ImGuiKey_Delete)) return mw.doDelete(false);
        if (pressed(shift | im.ImGuiKey_Delete)) return mw.doDelete(true);
        if (pressed(im.ImGuiKey_F2)) return mw.beginRename();
        if (pressed(ctrl | im.ImGuiKey_A)) return m.selectAll();
        if (pressed(ctrl | im.ImGuiKey_C) or pressed(ctrl | im.ImGuiKey_Insert)) return mw.copyFiles();
        if (pressed(ctrl | im.ImGuiKey_V) or pressed(shift | im.ImGuiKey_Insert)) return mw.pasteFiles();
        if (pressed(im.ImGuiKey_KeypadAdd)) return mw.selectGroup(true);
        if (pressed(im.ImGuiKey_KeypadSubtract)) return mw.selectGroup(false);
        if (pressed(im.ImGuiKey_KeypadMultiply)) return m.invert();
    }

    // ---- navigation glue -------------------------------------------------------------------------------------

    /// A navigation's outcome: NeedOpen -> Dialogs.openArchive (its own alerts and prompts), NotFound -> the
    /// path-not-found alert, anything else -> the error's text.
    fn nav(mw: *MainWindow, r: anyerror!void) void {
        r catch |e| mw.navError(e);
    }

    fn navError(mw: *MainWindow, e: anyerror) void {
        const d = mw.ctx.dialogs;
        switch (e) {
            error.NeedOpen => {
                const want = mw.m.want orelse return;
                mw.m.want = null;
                const t = mw.token();
                mw.pending.put(mw.ctx.gpa, t, .{ .go = want }) catch {
                    var x = want;
                    x.saved.deinit();
                    return;
                };
                d.openArchive(want.saved.loc.path, want.saved.loc.password, t);
            },
            error.NotFound => {
                var b: [2200]u8 = undefined;
                const path = if (mw.m.want) |x| x.saved.loc.path else "";
                d.alert(.err, S.app, S.fillZ(&b, S.tr().pathNotFoundFmt, .{path}));
                mw.m.clearWant();
            },
            else => d.alert(.err, S.tr().@"error", engine.friendly(e, null)),
        }
    }

    fn act(mw: *MainWindow, r: anyerror!model.Action) void {
        const a = r catch |e| return mw.navError(e);
        switch (a) {
            .none => {},
            .shell => |p| shell.open(mw.ctx.gpa, p) catch |e| mw.ctx.dialogs.alert(.err, S.tr().@"error", engine.friendly(e, null)),
            .extract => |x| {
                const arc = mw.m.a orelse return;
                const rel = mw.ctx.dupe(x.rel) catch return;
                const t = mw.token();
                mw.pending.put(mw.ctx.gpa, t, .{ .open_temp = .{ .rel = rel, .as_archive = x.as_archive } }) catch return mw.ctx.gpa.free(rel);
                mw.ctx.dialogs.extractToTemp(arc, &.{x.index}, t);
            },
        }
    }

    fn token(mw: *MainWindow) C.Token {
        defer mw.next_token +%= 1;
        return mw.next_token;
    }

    fn say(mw: *MainWindow, text: [:0]const u8) void {
        mw.ctx.dialogs.alert(.info, S.app, text);
    }

    // ---- commands ---------------------------------------------------------------------------------------------

    fn doOpen(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        var tb: [64]u8 = undefined;
        const filters = [_]kit.win.Filter{
            .{ .name = S.tr().archives, .spec = "*.7z;*.zip;*.rar;*.tar;*.gz;*.tgz;*.bz2;*.tbz2;*.xz;*.txz;*.wim;*.iso;*.cab;*.lzh;*.arj;*.cpio;*.rpm;*.deb;*.msi;*.chm;*.dmg;*.vhd;*.001" },
            .{ .name = S.tr().allFiles, .spec = "*.*" },
        };
        const r = kit.win.openFiles(gpa, mw.ctx.app.hwnd, false, .{ .title = noDots(S.plain(&tb, S.tr().open)), .filters = &filters, .folder = mw.m.dir }) catch return;
        const list = r orelse return;
        defer kit.win.freeList(gpa, list);
        if (list.len > 0) mw.open(list[0]);
    }

    /// Alt+A. On disk: the selection goes to the New archive dialog. In an archive: files are added to it.
    fn doAdd(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        if (mw.m.a) |a| {
            var tb: [64]u8 = undefined;
            // ponytail: files only here - folders come in by drag and drop or Ctrl+V (a folder picker is the upgrade path).
            const r = kit.win.openFiles(gpa, mw.ctx.app.hwnd, true, .{ .title = noDots(S.plain(&tb, S.tr().addFilesToArchive)), .filters = &.{.{ .name = S.tr().allFiles, .spec = "*.*" }} }) catch return;
            const list = r orelse return;
            defer kit.win.freeList(gpa, list);
            if (list.len > 0) mw.ctx.dialogs.addToArchive(a, @ptrCast(list), mw.m.cur, mw.m.editable);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const paths = mw.m.selectedPaths(arena.allocator(), false) catch return;
        if (paths.len == 0) return mw.say(S.tr().nothingSelected);
        const args = arena.allocator().alloc([]const u8, paths.len + 1) catch return;
        args[0] = "a";
        @memcpy(args[1..], paths);
        mw.ctx.dialogs.dispatch(args);
    }

    /// The selected archives on disk; a message (and an empty list) when there are none.
    fn selectedArchives(mw: *MainWindow, ar: Allocator) [][]const u8 {
        const files = mw.m.selectedPaths(ar, true) catch return &.{};
        if (files.len == 0) mw.say(if (mw.m.anySelected()) S.tr().noArchivesSelected else S.tr().nothingSelected);
        return files;
    }

    fn doExtract(mw: *MainWindow) void {
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        const a = mw.m.a orelse {
            for (mw.selectedArchives(ar)) |p| mw.ctx.dialogs.dispatch(&.{ "x", p }); // the queue says n/N
            return;
        };
        const indices = mw.m.selected(ar) catch return;
        // Only the whole archive on disk, extracted without an error, is ever offered for deletion.
        mw.ctx.dialogs.extract(a, indices, indices == null and mw.m.parents.len == 0);
    }

    /// Alt+W: into a folder named after the archive, next to it, no dialog.
    fn doExtractNoAsk(mw: *MainWindow) void {
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        const a = mw.m.a orelse {
            for (mw.selectedArchives(ar)) |p| mw.ctx.dialogs.dispatch(&.{ "x", p, "--sub" });
            return;
        };
        const indices = mw.m.selected(ar) catch return;
        const dest = model.join(ar, mw.m.dir, engine.baseName(a.display())) catch return;
        mw.ctx.dialogs.extractTo(a, indices, dest);
    }

    fn doTest(mw: *MainWindow) void {
        if (mw.m.a) |a| {
            // C# TestOne had no Ready(): bodies with a password failed with the CLI's "-p" text. Ask first, as Alt+E.
            if (!mw.m.encrypted) return mw.ctx.dialogs.testArchive(a);
            const t = mw.token();
            mw.pending.put(mw.ctx.gpa, t, .test_arc) catch return;
            return mw.ctx.dialogs.ready(a, t);
        }
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const files = mw.selectedArchives(arena.allocator());
        if (files.len > 0) mw.ctx.dialogs.testFiles(files);
    }

    /// Alt+V: the internal viewer for a file; a folder is simply entered.
    fn doView(mw: *MainWindow) void {
        const m = &mw.m;
        const i = m.oneSelected() orelse return mw.say(S.tr().nothingSelected);
        const r = m.rows.items[i];
        if (r.folder) return mw.act(m.activate(i, false));
        if (m.a) |a| return mw.ctx.dialogs.viewEntry(a, r.entry orelse return, r.name);
        const path = m.diskPath(r.name) catch return;
        mw.ctx.dialogs.view(path, r.name);
    }

    fn doDelete(mw: *MainWindow, nuke: bool) void {
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        if (mw.m.a) |a| {
            const indices = (mw.m.selected(ar) catch return) orelse return;
            if (indices.len == 0) return;
            if (!mw.m.editable) return mw.say(S.tr().notSupported);
            return mw.ctx.dialogs.deleteEntries(a, indices, mw.m.selectedCount(), mw.m.cur);
        }
        const paths = mw.m.selectedPaths(ar, false) catch return;
        if (paths.len > 0) mw.ctx.dialogs.deleteFiles(paths, nuke);
    }

    fn doInfo(mw: *MainWindow) void {
        const m = &mw.m;
        if (m.a) |a| return mw.ctx.dialogs.info(a);
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const paths = m.selectedPaths(arena.allocator(), false) catch return;
        if (paths.len == 1) if (m.oneSelected()) |i| if (!m.rows.items[i].folder and m.isArchiveFile(paths[0])) return mw.ctx.dialogs.infoFile(paths[0]);
        shell.properties(mw.ctx.gpa, if (paths.len > 0) paths[0] else m.dir);
    }

    fn doFind(mw: *MainWindow) void {
        mw.ctx.dialogs.find(if (mw.m.a) |a| a.source else mw.m.dir);
    }

    fn saveReport(mw: *MainWindow, html: bool) void {
        const a = mw.m.a orelse return;
        mw.ctx.dialogs.saveReport(a, html, mw.m.dir);
    }

    fn copyReport(mw: *MainWindow) void {
        const a = mw.m.a orelse return;
        const gpa = mw.ctx.gpa;
        const text = engine.report(gpa, mw.ctx.io, a, false) catch |e| return mw.ctx.dialogs.alert(.err, S.tr().@"error", engine.friendly(e, null));
        defer gpa.free(text);
        if (shell.setText(gpa, mw.ctx.app.hwnd, text)) mw.m.setMessage(S.tr().reportCopied);
    }

    /// Convert the selected archives (on disk) or the open one - closed while converting, reopened after.
    fn doConvert(mw: *MainWindow) void {
        if (mw.m.a) |a| {
            if (mw.m.parents.len > 0) return mw.say(S.tr().notSupported);
            return mw.ctx.dialogs.convert(&.{a.source}, true);
        }
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const files = mw.m.selectedPaths(arena.allocator(), true) catch return;
        mw.ctx.dialogs.convert(files, false);
    }

    fn toggleFlat(mw: *MainWindow) void {
        if (mw.m.a == null) return;
        mw.m.flat = !mw.m.flat;
        settings.current().FlatView = mw.m.flat;
        settings.commit();
        mw.m.fill(false, null) catch {};
    }

    fn setListMode(mw: *MainWindow, list: bool) void {
        mw.list_mode = list;
        settings.current().ListMode = list;
        settings.commit();
    }

    fn toggleTree(mw: *MainWindow) void {
        mw.show_tree = !mw.show_tree;
        settings.current().Tree = mw.show_tree;
        settings.commit();
        mw.tree.built = false;
    }

    fn selectGroup(mw: *MainWindow, on: bool) void {
        var tb: [128]u8 = undefined;
        const t = mw.token();
        mw.pending.put(mw.ctx.gpa, t, .{ .mask = on }) catch return;
        mw.ctx.dialogs.nameLine(noDots(S.plain(&tb, (if (on) S.tr().selectGroup else S.tr().deselectGroup))), S.tr().maskPrompt, mw.mask, t);
    }

    // ---- rename / new folder -------------------------------------------------------------------------------

    fn beginRename(mw: *MainWindow) void {
        const m = &mw.m;
        const f = m.focus orelse return;
        if (f >= m.rows.items.len) return;
        const r = m.rows.items[f];
        if (!r.selected or r.up or (m.a != null and !m.editable)) return;
        const old = mw.ctx.dupe(r.name) catch return;
        if (mw.edit_old) |o| mw.ctx.gpa.free(o);
        mw.edit_old = old;
        const n = @min(r.name.len, mw.edit_buf.len - 1);
        @memcpy(mw.edit_buf[0..n], r.name[0..n]);
        mw.edit_buf[n] = 0;
        mw.edit = f;
        mw.edit_frames = 0;
    }

    /// The label editor: Enter or a click elsewhere commits, Esc cancels (the list is refilled either way).
    fn renameBox(mw: *MainWindow) void {
        if (mw.edit_frames == 0) im.ImGui_SetKeyboardFocusHere();
        if (mw.list_mode) {} else im.ImGui_SetNextItemWidth(-1);
        // No vertical frame padding: the box is as tall as a row, the icon beside it stays centred.
        im.ImGui_PushStyleVarY(im.ImGuiStyleVar_FramePadding, 0);
        const enter = im.ImGui_InputText("##rename", &mw.edit_buf, mw.edit_buf.len, im.ImGuiInputTextFlags_EnterReturnsTrue | im.ImGuiInputTextFlags_AutoSelectAll);
        im.ImGui_PopStyleVar();
        mw.edit_frames += 1;
        const gone = im.ImGui_IsItemDeactivated() or (mw.edit_frames > 3 and !im.ImGui_IsItemActive());
        if (!enter and !gone) return;
        mw.edit_cancel = !enter and im.ImGui_IsKeyPressed(im.ImGuiKey_Escape);
        mw.after = .rename;
    }

    fn commitRename(mw: *MainWindow) void {
        mw.edit = null;
        mw.focus_list = true;
        const old = mw.edit_old orelse return;
        mw.edit_old = null;
        defer mw.ctx.gpa.free(old);
        if (mw.edit_cancel) return;
        const name = std.mem.trim(u8, std.mem.sliceTo(&mw.edit_buf, 0), " ");
        if (std.mem.eql(u8, name, old)) return;
        mw.doRename(old, name);
    }

    fn doRename(mw: *MainWindow, old: []const u8, name: []const u8) void {
        const m = &mw.m;
        m.checkName(old, name) catch |e| return mw.say(if (e == error.BadName) S.tr().badName else S.tr().nameTaken);
        const gpa = mw.ctx.gpa;
        if (m.a) |a| return mw.ctx.dialogs.renameEntry(a, m.cur, old, name);
        const from = model.join(gpa, m.dir, old) catch return;
        defer gpa.free(from);
        const to = model.join(gpa, m.dir, name) catch return;
        defer gpa.free(to);
        shell.rename(gpa, from, to) catch |e| mw.ctx.dialogs.alert(.err, S.tr().@"error", engine.friendly(e, null));
        const keep = gpa.dupe(u8, name) catch return;
        defer gpa.free(keep);
        m.fill(false, keep) catch {};
        mw.focus_list = true;
    }

    fn newFolder(mw: *MainWindow) void {
        const i = (mw.m.newFolder() catch |e| return mw.ctx.dialogs.alert(.err, S.tr().@"error", engine.friendly(e, null))) orelse return;
        mw.m.focus = i;
        mw.beginRename();
    }

    // ---- clipboard ------------------------------------------------------------------------------------------

    /// Ctrl+C: files Explorer can paste. From an archive they are extracted to temp first, as on drag-out.
    fn copyFiles(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        const a = mw.m.a orelse {
            const paths = mw.m.selectedPaths(ar, false) catch return;
            if (paths.len > 0) _ = shell.setFiles(gpa, mw.ctx.app.hwnd, paths);
            return;
        };
        const indices = (mw.m.selected(ar) catch return) orelse return;
        if (indices.len == 0) return;
        const rels = mw.selectedRels(gpa) catch return;
        const t = mw.token();
        mw.pending.put(gpa, t, .{ .copy_files = rels }) catch {
            for (rels) |s| gpa.free(s);
            gpa.free(rels);
            return;
        };
        mw.ctx.dialogs.extractToTemp(a, indices, t);
    }

    /// The selected rows' entry names inside the archive, with backslashes (temp-dir relative paths). gpa-owned.
    fn selectedRels(mw: *MainWindow, gpa: Allocator) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        for (mw.m.rows.items) |r| if (r.selected and !r.up) {
            const n = try mw.m.entryName(gpa, r);
            std.mem.replaceScalar(u8, n, '/', '\\');
            try list.append(gpa, n);
        };
        return list.toOwnedSlice(gpa);
    }

    /// Ctrl+V: on disk a shell copy (or move, after a Cut in Explorer) into this folder; in an archive, Add.
    fn pasteFiles(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        const p = shell.getFiles(gpa, mw.ctx.app.hwnd) orelse return;
        defer p.deinit(gpa);
        if (mw.m.a) |a| return mw.ctx.dialogs.addToArchive(a, @ptrCast(p.files), mw.m.cur, mw.m.editable);
        _ = shell.copy(gpa, mw.ctx.app.hwnd, @ptrCast(p.files), mw.m.dir, p.move);
        mw.m.fill(true, null) catch {};
    }

    fn copyNames(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var first = true;
        for (mw.m.rows.items) |r| if (r.selected and !r.up) {
            if (!first) out.writer.writeAll("\r\n") catch return;
            first = false;
            if (mw.m.a) |a| {
                const n = mw.m.entryName(gpa, r) catch return;
                defer gpa.free(n);
                std.mem.replaceScalar(u8, n, '/', '\\');
                out.writer.print("{s}\\{s}", .{ a.source, n }) catch return;
            } else out.writer.writeAll(mw.m.diskPath(r.name) catch return) catch return;
        };
        if (!first) _ = shell.setText(gpa, mw.ctx.app.hwnd, out.written());
    }

    // ---- favorites --------------------------------------------------------------------------------------------

    fn beginAddFavorite(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        const m = &mw.m;
        // A nested archive lives in a temp file: the favorite points at the archive on disk it came from.
        var path: []const u8 = m.dir;
        var inner: ?[]const u8 = null;
        if (m.a) |a| {
            path = if (m.parents.len > 0) m.parents[0].source else a.source;
            inner = if (m.parents.len > 0) "" else m.cur;
        }
        var nb: [1024]u8 = undefined;
        const name = if (m.a != null) m.where(&nb) else if (pw.fileName(m.dir).len > 0) pw.fileName(m.dir) else m.dir;
        const p = gpa.dupe(u8, path) catch return;
        const i: ?[]u8 = if (inner) |x| gpa.dupe(u8, x) catch return gpa.free(p) else null;
        const t = mw.token();
        mw.pending.put(gpa, t, .{ .favorite = .{ .path = p, .inner = i } }) catch {
            gpa.free(p);
            if (i) |x| gpa.free(x);
            return;
        };
        var tb: [128]u8 = undefined;
        mw.ctx.dialogs.nameLine(noDots(S.plain(&tb, S.tr().addFavorite)), S.tr().favoritePrompt, name, t);
    }

    fn addFavorite(mw: *MainWindow, name: []const u8, path: []const u8, inner: ?[]const u8) void {
        if (name.len == 0) return;
        const s = settings.current();
        const ar = settings.arena();
        const list = ar.alloc(settings.Favorite, s.Favorites.len + 1) catch return;
        @memcpy(list[0..s.Favorites.len], s.Favorites);
        list[s.Favorites.len] = .{
            .Name = ar.dupe(u8, name) catch return,
            .Path = ar.dupe(u8, path) catch return,
            .Inner = if (inner) |x| ar.dupe(u8, x) catch return else null,
        };
        s.Favorites = list;
        settings.commit();
        _ = mw;
    }

    fn goFavorite(mw: *MainWindow, i: usize) void {
        const favs = settings.current().Favorites;
        if (i >= favs.len) return;
        const f = favs[i];
        mw.nav(mw.m.go(.{ .path = f.Path, .inner = f.Inner }, null, true));
        mw.focus_list = true;
    }

    // ---- drag-out -----------------------------------------------------------------------------------------------

    /// Drag the selection out to Explorer: disk items as they are; archived ones extracted at drop time.
    fn dragOut(mw: *MainWindow) void {
        if (mw.m.a) |a| {
            // Ready(): the bodies' password first. Nothing encrypted = nothing to ask: drag right away.
            if (!mw.m.encrypted) return mw.dragArchive();
            const t = mw.token();
            mw.pending.put(mw.ctx.gpa, t, .drag) catch return;
            return mw.ctx.dialogs.ready(a, t);
        }
        var arena: std.heap.ArenaAllocator = .init(mw.ctx.gpa);
        defer arena.deinit();
        const paths = mw.m.selectedPaths(arena.allocator(), false) catch return;
        if (paths.len == 0) return;
        mw.runDrag(paths, w.DROPEFFECT_COPY | w.DROPEFFECT_MOVE | w.DROPEFFECT_LINK, null);
        mw.m.fill(true, null) catch {};
    }

    const DropJob = struct {
        mw: *MainWindow,
        a: *engine.Archive,
        dir: []const u8,
        indices: []const u32,

        fn run(ctx: *anyopaque) bool {
            const j: *DropJob = @ptrCast(@alignCast(ctx));
            const c = j.mw.ctx;
            var diag: engine.Diag = .{};
            engine.extract(c.gpa, c.io, j.a, j.dir, j.indices, .Overwrite, .none, .always_overwrite, settings.current().Motw, .{}, &diag) catch |e| {
                c.dialogs.alert(.err, S.tr().@"error", engine.friendly(e, &diag));
                return false;
            };
            return true;
        }
    };

    /// The 7-Zip way: temp-folder paths that do not exist yet; DropJob extracts them when the button goes up.
    fn dragArchive(mw: *MainWindow) void {
        const gpa = mw.ctx.gpa;
        const a = mw.m.a orelse return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        const indices = (mw.m.selected(ar) catch return) orelse return;
        if (indices.len == 0) return;
        // ponytail: the temp copy lives until MakePack exits.
        const dir = engine.newTempDir(ar, mw.ctx.io) catch return;
        const rels = mw.selectedRels(ar) catch return;
        const temp = ar.alloc([]const u8, rels.len) catch return;
        for (rels, temp) |r, *t| t.* = model.join(ar, dir, r) catch return;
        var job: DropJob = .{ .mw = mw, .a = a, .dir = dir, .indices = indices };
        mw.runDrag(temp, w.DROPEFFECT_COPY, .{ .ctx = &job, .run = DropJob.run });
    }

    fn runDrag(mw: *MainWindow, paths: []const []const u8, effects: w.DWORD, job: ?drag.Job) void {
        mw.dragging = true;
        _ = drag.run(paths, effects, job);
        mw.dragging = false;
        // A drop onto ourselves comes back as WM_DROPFILES after DoDragDrop returned: ignore it for a moment.
        mw.ignore_drops_until = w.GetTickCount64() + 1000;
        // OLE's modal loop ate the button release: tell ImGui, or the row stays "held".
        im.ImGuiIO_AddMouseButtonEvent(im.ImGui_GetIO(), 0, false);
    }

    // ---- window state -------------------------------------------------------------------------------------------

    fn underTest() bool {
        const v = kit.win.getEnv(std.heap.smp_allocator, "MAKEKIT_DISPLAY") catch null;
        defer if (v) |x| std.heap.smp_allocator.free(x);
        return v != null;
    }

    fn restoreLayout(mw: *MainWindow) void {
        const hwnd = mw.ctx.app.hwnd;
        if (hwnd == null) return;
        const s = settings.current();
        // A test (MAKEKIT_DISPLAY) keeps its window on the kit's monitor and never activates it: saved bounds apply
        // only when they lie on that monitor. ponytail: no SW_MAXIMIZE under test (it activates, and there is no
        // non-activating maximize); that one line is exercised by real runs only.
        const testing = underTest();
        const here = w.MonitorFromWindow(hwnd, w.MONITOR_DEFAULTTONULL);
        if (s.Window) |b| if (b.len == 4) {
            const rc: w.RECT = .{ .left = b[0], .top = b[1], .right = b[0] + b[2], .bottom = b[1] + b[3] };
            const mon = w.MonitorFromRect(&rc, w.MONITOR_DEFAULTTONULL);
            if (mon != null and (!testing or mon == here))
                _ = w.SetWindowPos(hwnd, null, b[0], b[1], @max(b[2], 640), @max(b[3], 400), @intCast(w.SWP_NOZORDER | w.SWP_NOACTIVATE));
        };
        if (testing) return;
        if (s.Window == null) {
            const sc = mw.scale();
            _ = w.SetWindowPos(hwnd, null, 0, 0, @intFromFloat(1000 * sc), @intFromFloat(640 * sc), @intCast(w.SWP_NOZORDER | w.SWP_NOACTIVATE | w.SWP_NOMOVE));
        }
        if (s.Maximized) _ = w.ShowWindow(hwnd, w.SW_MAXIMIZE);
    }

    /// The window's normal bounds and maximized state, every frame: by the time the window is closed with
    /// app.quit() (Exit, automation) the HWND is already gone.
    fn trackBounds(mw: *MainWindow) void {
        const hwnd = mw.ctx.app.hwnd;
        if (hwnd == null or w.IsWindow(hwnd) == 0) return;
        var pl = std.mem.zeroes(w.WINDOWPLACEMENT);
        pl.length = @sizeOf(w.WINDOWPLACEMENT);
        var rc: w.RECT = undefined;
        const zoomed = w.IsZoomed(hwnd) != 0;
        const iconic = w.IsIconic(hwnd) != 0;
        const got = if (zoomed or iconic) (w.GetWindowPlacement(hwnd, &pl) != 0) else (w.GetWindowRect(hwnd, &rc) != 0);
        if (!got) return;
        if (zoomed or iconic) rc = pl.rcNormalPosition;
        mw.bounds = .{ rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top };
        if (!iconic) mw.maximized = zoomed;
    }

    fn saveLayout(mw: *MainWindow) void {
        const s = settings.current();
        const ar = settings.arena();
        mw.trackBounds();
        if (mw.bounds) |b| if (ar.dupe(i32, &b)) |copy| {
            s.Window = copy;
        } else |_| {};
        s.Maximized = mw.maximized;
        s.LastFolder = ar.dupe(u8, mw.m.dir) catch s.LastFolder;
        s.Tree = mw.show_tree;
        s.ListMode = mw.list_mode;
        settings.commit();
    }
};

// ---- small helpers ----------------------------------------------------------------------------------------------

fn colTitle(c: Col) [:0]const u8 {
    return switch (c) {
        .name => S.tr().name,
        .size => S.tr().size,
        .@"packed" => S.tr().@"packed",
        .type => S.tr().type,
        .modified => S.tr().modified,
        .crc => S.tr().crc32,
        .path => S.tr().pathColumn,
    };
}

fn tooltip(comptime fmt: []const u8, args: anytype) void {
    if (!im.ImGui_IsItemHovered(im.ImGuiHoveredFlags_ForTooltip)) return;
    var b: [1024]u8 = undefined;
    const z = std.mem.printSentinel(&b, fmt, args, 0) catch return;
    im.ImGui_SetTooltipUnformatted(z.ptr);
}

fn pressed(chord: c_int) bool {
    return im.ImGui_IsKeyChordPressed(chord);
}

/// "Select group…" -> "Select group" (a dialog title).
fn noDots(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, "\u{2026}")) s[0 .. s.len - "\u{2026}".len] else s;
}

fn beginMenu(text: [:0]const u8, id: []const u8) bool {
    return beginMenuEx(text, id, true);
}

fn beginMenuEx(text: [:0]const u8, id: []const u8, enabled: bool) bool {
    var plain: [96]u8 = undefined;
    var label: [128]u8 = undefined;
    const z = std.mem.printSentinel(&label, "{s}###{s}", .{ S.plain(&plain, text), id }, 0) catch return false;
    return im.ImGui_BeginMenuEx(z.ptr, enabled);
}

fn item(text: [:0]const u8, id: []const u8, shortcut: ?[*:0]const u8, enabled: bool) bool {
    return checkItem(text, id, shortcut, false, enabled);
}

fn checkItem(text: [:0]const u8, id: []const u8, shortcut: ?[*:0]const u8, checked: bool, enabled: bool) bool {
    var plain: [160]u8 = undefined;
    var label: [200]u8 = undefined;
    const z = std.mem.printSentinel(&label, "{s}{s}###{s}", .{ gutter(), S.plain(&plain, text), id }, 0) catch return false;
    return im.ImGui_MenuItemEx(z.ptr, shortcut, checked, enabled);
}

/// Set while drawing a menu with pictures (Favorites): every label starts after a gutter where iconItem draws
/// its kit icon. ponytail: the gutter is spaces (ImGui's own icon column, MenuItemEx, is internal-only).
var menu_gutter = false;

fn gutter() []const u8 {
    if (!menu_gutter) return "";
    const spaces = "                "; // 16
    const n = @ceil((kit.icons.pixels(16) + im.ImGui_GetStyle().*.ItemSpacing.x) / spaceWidth());
    return spaces[0..@min(spaces.len, @as(usize, @intFromFloat(n)))];
}

/// One space of the current font. CalcTextSize rounds a width up to a whole pixel (" " = 4 px for Fira's 3.1),
/// so 16 spaces are measured at once.
fn spaceWidth() f32 {
    return @max(1, im.ImGui_CalcTextSize("                ").x / 16);
}

/// A 16 px kit icon centred on an `h` px high line: GetFrameHeight() for the status bar (its text sits
/// AlignTextToFramePadding-low), GetTextLineHeight() for list rows (the icon then adds no height to the row).
fn lineIcon(name: kit.icons.Name, h: f32) void {
    const p = im.ImGui_GetCursorScreenPos();
    im.ImGui_Dummy(.{ .x = kit.icons.pixels(16), .y = h });
    drawIcon16(name, p, h);
}

fn iconItem(icon: kit.icons.Name, text: [:0]const u8, id: []const u8, shortcut: ?[*:0]const u8) bool {
    const p = im.ImGui_GetCursorScreenPos();
    const clicked = item(text, id, shortcut, true);
    drawIcon16(icon, p, im.ImGui_GetItemRectSize().y);
    return clicked;
}

/// At `p.x`, vertically centred in a `h` px band from `p.y`, on whole pixels (the texture maps 1:1).
fn drawIcon16(name: kit.icons.Name, p: im.ImVec2, h: f32) void {
    const px = kit.icons.pixels(16);
    const x = @round(p.x);
    const y = @round(p.y + (h - px) / 2);
    if (kit.icons.get(name, 16)) |t| im.ImDrawList_AddImage(im.ImGui_GetWindowDrawList(), t, .{ .x = x, .y = y }, .{ .x = x + px, .y = y + px });
}
